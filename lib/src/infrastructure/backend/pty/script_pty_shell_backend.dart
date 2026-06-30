import 'dart:io';

import '../../../domain/backend/pty_spec.dart';
import '../../../domain/backend/shell_backend.dart';
import '../../../domain/backend/shell_request.dart';
import '../../../domain/backend/shell_session.dart';
import '../../../domain/entities/session.dart';
import '../process_shell_backend.dart';
import '../shell_invocation.dart';
import 'script_pty_shell_session.dart';

/// A [ShellBackend] that runs interactive shells on a real pseudo-terminal
/// allocated by the system `script(1)` utility — **without `dart:ffi` or any
/// native library**.
///
/// It is the default PTY backend. Because the pty, `forkpty` and signal handling
/// all live inside the `script` child process (an ordinary [Process] the VM
/// reaps the safe way), it cannot trigger the native `SIGCHLD` crash that
/// affects the FFI-based `PtyShellBackend`.
///
/// Like `PtyShellBackend` it decorates a [fallback] (the pipe-based
/// [ProcessShellBackend]) and delegates to it when:
///
/// - the request carries no [PtySpec] (e.g. `exec` mode), or
/// - the platform is Windows (no POSIX `script`/forkpty), or
/// - `script` is not installed, or a spawn fails — after the first such failure
///   the `script` path is disabled for the process and every session uses the
///   env-var fallback, which still conveys the initial geometry via
///   `COLUMNS`/`LINES`.
///
/// Trade-off vs the native backend: `script` launched from pipes has no
/// controlling terminal of its own, so live resize (`SIGWINCH`) cannot be
/// propagated to the child — [ScriptPtyShellSession.resize] is a no-op. The
/// initial geometry is still honoured (seeded via `stty` before `exec`).
class ScriptPtyShellBackend implements ShellBackend {
  /// The shell launched for interactive sessions without an explicit command.
  final String defaultShell;

  /// Working directory applied when a request does not specify one.
  final String? workingDirectory;

  /// Extra environment overlaid on the inherited environment for every session.
  final Map<String, String> baseEnvironment;

  /// Optional guard; when it returns `false` the session is refused.
  final bool Function(ShellRequest request)? allowCommand;

  /// Backend used for exec sessions and whenever the `script` path is
  /// unavailable.
  final ShellBackend fallback;

  /// Optional sink for a one-time warning when the `script` path is disabled.
  final void Function(String message)? onWarning;

  bool _scriptUsable = !Platform.isWindows && _scriptPath() != null;

  /// Creates a `script`-based PTY backend decorating [fallback].
  ScriptPtyShellBackend({
    required this.fallback,
    String? defaultShell,
    this.workingDirectory,
    this.baseEnvironment = const {},
    this.allowCommand,
    this.onWarning,
  }) : defaultShell = defaultShell ?? resolveDefaultShell();

  @override
  Future<ShellSession> start(ShellRequest request) async {
    final spec = request.pty;
    if (spec == null || !_scriptUsable) {
      return fallback.start(request);
    }

    if (allowCommand != null && !allowCommand!(request)) {
      throw ProcessException(
        request.command ?? defaultShell,
        request.args,
        'Command not permitted by node policy',
      );
    }

    Directory? ttyDir;
    try {
      final script = _scriptPath();
      if (script == null) throw StateError('script(1) not found');
      // A unique per-session temp file the wrapper records its controlling-tty
      // path into (via `tty`), so [ScriptPtyShellSession.resize] can target the
      // child PTS with `stty` — `script` over pipes leaves the node no pty fd.
      ttyDir = Directory.systemTemp.createTempSync('omnyshell-pts-');
      final ttyFile = '${ttyDir.path}/tty';
      final (executable, args) = _scriptInvocation(request, spec, ttyFile);
      final process = await Process.start(
        script,
        args,
        workingDirectory: request.cwd ?? workingDirectory,
        environment: {
          ...baseEnvironment,
          ..._environment(spec),
          ...request.env,
        },
        includeParentEnvironment: true,
      );
      return ScriptPtyShellSession(process, ttyFile: ttyFile, ttyDir: ttyDir);
    } on Object catch (e) {
      // Disable the `script` path for the rest of the process and fall back so
      // the session still works (with env-var geometry) instead of being
      // rejected.
      try {
        ttyDir?.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup of the unused temp dir.
      }
      _scriptUsable = false;
      onWarning?.call(
        'script PTY backend unavailable, using pipe fallback: $e',
      );
      return fallback.start(request);
    }
  }

  /// Builds the `script` argv. The shell is wrapped so the child records its
  /// controlling-tty path (`tty` → [ttyFile], for live resize) and seeds its own
  /// window size (real `TIOCSWINSZ`) before `exec`ing the shell, since `script`
  /// from pipes starts the pty at 0×0.
  ///
  /// In `shell` mode the shell is run **non-interactively**, reading its command
  /// stream from the PTY via `/dev/stdin`, and terminal echo is disabled. This
  /// keeps a real PTY (so full-screen apps and geometry work) while suppressing
  /// the shell's own prompt and input echo — the client's managed prompt is then
  /// the only one shown, matching the prompt-free behaviour of the pipe-based
  /// fallback that the `CwdMarker` design assumes. `exec` mode is unchanged.
  (String, List<String>) _scriptInvocation(
    ShellRequest request,
    PtySpec spec,
    String ttyFile,
  ) {
    final (shell, shellArgs) = resolveShellInvocation(request, defaultShell);
    final isShell = request.mode == SessionMode.shell;
    final argv = isShell
        ? [shell, ...shellArgs, '/dev/stdin']
        : [shell, ...shellArgs];
    final command = argv.map(_singleQuote).join(' ');
    final echo = isShell ? '-echo ' : '';
    final inner =
        'tty > ${_singleQuote(ttyFile)} 2>/dev/null; '
        'stty ${echo}rows ${spec.rows} cols ${spec.cols} 2>/dev/null; exec $command';

    if (Platform.isLinux) {
      // util-linux: -q quiet, -e return child's exit code, -c run command.
      return ('script', ['-q', '-e', '-c', inner, '/dev/null']);
    }
    // BSD/macOS: `script -q <file> <command…>`; run the wrapper via /bin/sh -c.
    return ('script', ['-q', '/dev/null', '/bin/sh', '-c', inner]);
  }

  /// Environment for the child. `TERM` carries the negotiated terminal type;
  /// `COLUMNS`/`LINES` mirror the seeded geometry as a hint for programs that
  /// read the environment (the real window size is also set via `stty`).
  Map<String, String> _environment(PtySpec spec) => {
    'TERM': spec.term,
    'COLUMNS': '${spec.cols}',
    'LINES': '${spec.rows}',
  };

  /// Cached absolute path to `script(1)`, or `null` when not installed.
  static String? _scriptPath() {
    if (_resolvedScript != _unresolved) return _resolvedScript;
    for (final candidate in const ['/usr/bin/script', '/bin/script']) {
      if (File(candidate).existsSync()) {
        return _resolvedScript = candidate;
      }
    }
    return _resolvedScript = null;
  }

  static const String _unresolved = 'unresolved';
  static String? _resolvedScript = _unresolved;

  static String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}
