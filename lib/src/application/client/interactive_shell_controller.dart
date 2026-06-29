import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/backend/shell_family.dart';
import 'command_classifier.dart';
import 'cwd_marker.dart';
import 'shell_dialect.dart';
import 'shell_session_port.dart';

/// The remote shell's prompt context, reported to the host when the shell
/// returns to its (idle) prompt so the host can render a prompt line.
class ShellPromptState {
  /// The remote working directory, or `null` if unknown.
  final String? cwd;

  /// The git branch of [cwd], or `null` outside a repo.
  final String? branch;

  /// Compact git status (`+staged ~modified ?untracked`), or `null` when clean.
  final String? gitStatus;

  /// Privilege label (`root` for the superuser), or `null`.
  final String? privilege;

  /// Creates a prompt state.
  const ShellPromptState({
    this.cwd,
    this.branch,
    this.gitStatus,
    this.privilege,
  });

  /// Whether the remote session is the superuser.
  bool get isRoot => privilege == 'root';
}

/// Drives a [ShellSessionPort] as an interactive shell, terminal-agnostically.
///
/// OmnyShell runs the remote shell as a **pipe (no PTY)**: it emits no prompt
/// and no input echo, and there is no completion signal. This controller
/// supplies that missing protocol layer — the same one the CLI's `connect` loop
/// and the web client both need:
///
/// - **priming** — runs the dialect's [ShellDialect.initLine] and an initial
///   marker so the host can draw the first prompt with the starting cwd;
/// - **command dispatch** — on [submitLine] it wraps the command with a
///   [CwdMarker] tail via [ShellDialect.wrapCommand] (a full marker when the
///   line may change cwd/git state, a lighter ping otherwise), enters raw
///   passthrough, and waits for the marker;
/// - **output processing** — feeds remote stdout through [CwdMarker], emitting
///   marker-stripped output and replenishing the send window, and on completion
///   leaves passthrough and reports a [ShellPromptState];
/// - **resume** — when [resumedInAltScreen], starts in passthrough (the replayed
///   output repaints the program) and fetches the cwd once the program exits.
///
/// What stays with the **host** (and differs per embedder) is line editing and
/// prompt *rendering*: the host echoes input, manages the line buffer / history
/// / completion, formats the prompt from [ShellPromptState], and relays raw
/// bytes via [sendRaw] while a program owns the terminal. The host learns the
/// mode from the `onPassthrough` callback.
///
/// The captured result of running a command in the interactive session via
/// [InteractiveShellController.runAgentCommand].
class ShellRunResult {
  const ShellRunResult(this.output, this.exitCode);

  /// Marker-stripped stdout+stderr produced by the command.
  final List<int> output;

  /// The command's exit code, or `null` if the shell did not report one (e.g. a
  /// non-POSIX dialect whose marker omits it).
  final int? exitCode;
}

/// Pure Dart (no `dart:io`, no DOM), so the orchestration is identical and
/// unit-testable across the CLI, the browser, and any other embedder.
class InteractiveShellController {
  final ShellSessionPort _session;
  final CwdMarker _marker;
  final ShellDialect _dialect;
  final bool _resumedInAltScreen;
  final bool _interactive;

  /// Marker-stripped remote stdout to render (markers removed). Raw stderr is
  /// also routed here unless [onStderr] is provided.
  final void Function(List<int> output) onOutput;

  /// Raw remote stderr, if the host wants it kept separate from [onOutput]
  /// (e.g. the CLI writes it to its own stderr). When `null`, stderr folds into
  /// [onOutput].
  final void Function(List<int> bytes)? onStderr;

  /// The shell returned to its prompt; render a prompt from [state].
  final void Function(ShellPromptState state) onPrompt;

  /// Passthrough toggled: while `true` a program owns the terminal (the host
  /// should stop local line editing and relay raw bytes via [sendRaw]).
  final void Function(bool active) onPassthrough;

  /// The session ended with the given exit code (or `-1` if it closed uncleanly).
  final void Function(int code)? onExit;

  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;
  bool _started = false;
  bool _inFlight = false;
  bool _ended = false;
  bool _pendingResumeCwd;

  // Active [runAgentCommand]: the completer to resolve and the buffer that tees
  // the command's marker-stripped output (stdout+stderr) for the caller, while
  // it still streams live to [onOutput]/[onStderr].
  Completer<ShellRunResult>? _agentRun;
  BytesBuilder? _agentCapture;

  String? _cwd;
  String? _branch;
  String? _gitStatus;
  String? _privilege;

  /// Creates a controller over [session]. [marker] defaults to one seeded from
  /// the session id (so a resumed session reuses the original completion token).
  InteractiveShellController({
    required ShellSessionPort session,
    required this.onOutput,
    required this.onPrompt,
    required this.onPassthrough,
    this.onStderr,
    this.onExit,
    bool resumedInAltScreen = false,
    bool interactive = true,
    CwdMarker? marker,
  }) : _session = session,
       _marker = marker ?? CwdMarker(session.id?.value),
       _dialect = ShellDialect.forFamily(session.shellFamily),
       _resumedInAltScreen = resumedInAltScreen,
       _interactive = interactive,
       _pendingResumeCwd = resumedInAltScreen;

  /// Whether a command currently owns the terminal (raw passthrough).
  bool get inFlight => _inFlight;

  /// Whether the session has ended.
  bool get ended => _ended;

  /// The remote shell family (for completion routing in the host).
  ShellFamily get shellFamily => _session.shellFamily;

  /// Subscribes to the session and primes the first prompt. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    _stdoutSub = _session.stdout.listen(_onStdout);
    _stderrSub = _session.stderr.listen(_onStderr);
    unawaited(
      _session.exitCode.then(_onExitCode).catchError((_) {
        _onExitCode(-1);
      }),
    );

    if (_resumedInAltScreen) {
      // Resuming into a full-screen program: the replayed output repaints it and
      // its already-queued completion marker restores the prompt when it exits.
      _inFlight = true;
      onPassthrough(true);
      return;
    }
    final init = _dialect.initLine;
    if (init != null) _send('$init\n');
    _send('${_dialect.fullMarker(_marker)}\n');
  }

  void _onStdout(Uint8List bytes) {
    // Drop output once detached: writing it (and the prompt repaint) would smear
    // escape sequences onto the terminal after the session is already gone.
    if (_ended || _session.wasDetached || bytes.isEmpty) return;
    // Replenish the node's send window for the raw bytes consumed; without this
    // the channel's credit drains and output stalls (e.g. a TUI repainting).
    _session.grantWindow(bytes.length);
    final scan = _marker.feed(bytes);
    if (scan.output.isNotEmpty) {
      onOutput(scan.output);
      _agentCapture?.add(scan.output);
    }
    if (scan.cwd != null) {
      _cwd = scan.cwd;
      _branch = scan.branch;
      _gitStatus = scan.gitStatus;
      _privilege = scan.privilege;
    }
    if (scan.completed) {
      _inFlight = false;
      onPassthrough(false);
      if (_pendingResumeCwd && _cwd == null) {
        // Resumed full-screen program just exited and we still don't know the
        // cwd: fetch it once (the prompt repaints when this marker completes).
        _pendingResumeCwd = false;
        _send('${_dialect.fullMarker(_marker)}\n');
      } else {
        onPrompt(_promptState());
      }
      _resolveAgentRun(scan.exitCode);
    }
  }

  void _onStderr(Uint8List bytes) {
    if (_ended || _session.wasDetached || bytes.isEmpty) return;
    _session.grantWindow(bytes.length);
    (onStderr ?? onOutput)(bytes);
    // Tee stderr into an active agent capture so the model sees error text too.
    _agentCapture?.add(bytes);
  }

  void _resolveAgentRun(int? exitCode) {
    final run = _agentRun;
    if (run == null) return;
    _agentRun = null;
    final output = _agentCapture?.takeBytes() ?? Uint8List(0);
    _agentCapture = null;
    if (!run.isCompleted) run.complete(ShellRunResult(output, exitCode));
  }

  ShellPromptState _promptState() => ShellPromptState(
    cwd: _cwd,
    branch: _branch,
    gitStatus: _gitStatus,
    privilege: _privilege,
  );

  /// Submits a committed command [line] (the host performed the line editing).
  ///
  /// A blank line just repaints the prompt; otherwise the command is wrapped
  /// with a marker tail and dispatched, and the terminal enters passthrough
  /// until the marker returns.
  void submitLine(String line) {
    if (_ended) return;
    if (line.trim().isEmpty) {
      onPrompt(_promptState());
      return;
    }
    _inFlight = true;
    onPassthrough(true);
    final tail = mayChangeCwdOrGit(line)
        ? _dialect.fullMarker(_marker)
        : _dialect.pingMarker(_marker);
    final command = _dialect.wrapCommand(
      line,
      interactive: _interactive,
      tail: tail,
    );
    _send('$command\n');
  }

  /// Runs [line] in this (the user's current) interactive session and returns
  /// its captured output and exit code — used by the AI agent so its commands
  /// run in the real terminal shell (with a PTY, shared cwd/env and sudo
  /// credentials), streaming live and letting the user answer prompts.
  ///
  /// Rejects if the session has ended or a command is already in flight. The
  /// command's output still streams to [onOutput]/[onStderr] (the user sees it)
  /// while it is also captured for the caller.
  Future<ShellRunResult> runAgentCommand(String line) {
    if (_ended) {
      return Future.error(StateError('session has ended'));
    }
    if (_inFlight || _agentRun != null) {
      return Future.error(StateError('a command is already running'));
    }
    if (line.trim().isEmpty) {
      return Future.value(const ShellRunResult(<int>[], 0));
    }
    final completer = Completer<ShellRunResult>();
    _agentRun = completer;
    _agentCapture = BytesBuilder(copy: false);
    _inFlight = true;
    onPassthrough(true);
    final command = _dialect.wrapCommand(
      line,
      interactive: _interactive,
      tail: _dialect.agentMarker(_marker),
    );
    _send('$command\n');
    return completer.future;
  }

  /// Relays raw [bytes] to the session — used by the host for passthrough input
  /// (every keystroke while a program owns the terminal).
  void sendRaw(List<int> bytes) {
    if (_ended) return;
    _session.writeStdin(bytes);
  }

  /// Sends an interrupt (Ctrl-C / SIGINT) to the remote process.
  void interrupt() => _session.interrupt();

  /// Forwards a terminal resize to the remote PTY.
  void resize(int cols, int rows) => _session.resize(cols: cols, rows: rows);

  void _send(String text) => _session.writeStdin(utf8.encode(text));

  void _onExitCode(int code) {
    if (_ended) return;
    _ended = true;
    // Fail any in-flight agent command so its caller does not hang.
    final run = _agentRun;
    if (run != null && !run.isCompleted) {
      _agentRun = null;
      _agentCapture = null;
      run.completeError(StateError('session ended during command'));
    }
    onExit?.call(code);
  }

  /// Detaches the session (keeps it alive on the node) and stops driving it.
  Future<void> detach() async {
    await _teardown();
    await _session.detach();
  }

  /// Terminates the session and stops driving it.
  Future<void> close() async {
    await _teardown();
    await _session.close();
  }

  /// Stops driving the session without detaching or closing it (host unmount).
  Future<void> dispose() => _teardown();

  Future<void> _teardown() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
  }
}
