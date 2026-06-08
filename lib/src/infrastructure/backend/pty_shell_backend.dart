import 'dart:io';

import 'package:portable_pty/portable_pty.dart';

import '../../domain/backend/pty_spec.dart';
import '../../domain/backend/shell_backend.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/backend/shell_session.dart';
import 'process_shell_backend.dart';
import 'pty_shell_session.dart';
import 'shell_invocation.dart';

/// A [ShellBackend] that runs interactive shells on a real pseudo-terminal via
/// `portable_pty`, giving full terminal semantics (`isatty()`, correct window
/// size, live resize via `TIOCSWINSZ`).
///
/// It is a decorator over a [fallback] backend (the pipe-based
/// [ProcessShellBackend]) and delegates to it when:
///
/// - the request carries no [PtySpec] (e.g. `exec` mode), or
/// - the platform has no POSIX master fd (Windows / ConPTY), or
/// - the native PTY library cannot be loaded or a spawn fails — after the first
///   such failure the PTY path is disabled for the process and every session
///   uses the env-var fallback, which still conveys the initial geometry via
///   `COLUMNS`/`LINES`.
class PtyShellBackend implements ShellBackend {
  /// The shell launched for interactive sessions without an explicit command.
  final String defaultShell;

  /// Working directory applied when a request does not specify one.
  final String? workingDirectory;

  /// Extra environment overlaid on the inherited environment for every session.
  final Map<String, String> baseEnvironment;

  /// Optional guard; when it returns `false` the session is refused.
  final bool Function(ShellRequest request)? allowCommand;

  /// Backend used for exec sessions and whenever the PTY path is unavailable.
  final ShellBackend fallback;

  /// Optional sink for a one-time warning when the PTY path is disabled.
  final void Function(String message)? onWarning;

  bool _ptyUsable = !Platform.isWindows;

  /// Creates a PTY backend decorating [fallback].
  PtyShellBackend({
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
    if (spec == null || !_ptyUsable) {
      return fallback.start(request);
    }

    if (allowCommand != null && !allowCommand!(request)) {
      throw ProcessException(
        request.command ?? defaultShell,
        request.args,
        'Command not permitted by node policy',
      );
    }

    PortablePty? pty;
    try {
      final (executable, args) = _invocation(request);
      pty = PortablePty.open(rows: spec.rows, cols: spec.cols);
      pty.spawn(
        executable,
        args: args,
        environment: _environment(request, spec),
      );
      if (pty.masterFd < 0) {
        // No POSIX master fd (e.g. ConPTY): the poll-based reader cannot work.
        throw StateError('PTY has no POSIX master fd');
      }
      return PtyShellSession(pty, pid: pty.childPid);
    } on Object catch (e) {
      try {
        pty?.close();
      } on Object {
        // Ignore cleanup failure.
      }
      // Disable the PTY path for the rest of the process and fall back so the
      // session still works (with env-var geometry) instead of being rejected.
      _ptyUsable = false;
      onWarning?.call('PTY backend unavailable, using pipe fallback: $e');
      return fallback.start(request);
    }
  }

  /// Resolves the executable/args, wrapping in `sh -c 'cd <cwd>; exec …'` when a
  /// working directory is set, because `portable_pty.spawn` has no cwd option.
  (String, List<String>) _invocation(ShellRequest request) {
    final (shell, shellArgs) = resolveShellInvocation(request, defaultShell);
    final cwd = request.cwd ?? workingDirectory;
    if (cwd == null || cwd.isEmpty) {
      return (shell, shellArgs);
    }
    return (
      '/bin/sh',
      [
        '-c',
        'cd ${_singleQuote(cwd)} 2>/dev/null; exec "\$0" "\$@"',
        shell,
        ...shellArgs,
      ],
    );
  }

  /// Environment for the child. `TERM` carries the negotiated terminal type;
  /// `COLUMNS`/`LINES` are deliberately removed so terminal-aware programs read
  /// the live kernel window size (which `resize` keeps current) rather than a
  /// stale env value — ncurses otherwise prefers the env over the `ioctl`.
  Map<String, String> _environment(ShellRequest request, PtySpec spec) =>
      <String, String>{
          ...Platform.environment,
          ...baseEnvironment,
          ...request.env,
          'TERM': spec.term,
        }
        ..remove('COLUMNS')
        ..remove('LINES');

  static String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}
