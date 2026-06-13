import 'dart:io';

import '../../domain/backend/shell_backend.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/backend/shell_session.dart';
import '../../shared/utils/omnyshell_home.dart';
import 'process_shell_session.dart';
import 'shell_invocation.dart';

/// A [ShellBackend] that runs commands and interactive shells as OS processes.
///
/// - **exec** runs the request through a shell (`<shell> -c "<command>"`) so a
///   full command line works, unless explicit [ShellRequest.args] are provided,
///   in which case the program is executed directly.
/// - **shell** launches an interactive login shell.
///
/// The default shell is resolved from `$SHELL` (POSIX) or `cmd.exe` (Windows),
/// overridable via [defaultShell]. An optional [allowCommand] predicate can veto
/// commands for least-privilege deployments.
class ProcessShellBackend implements ShellBackend {
  /// The shell used for exec mode and as the default interactive shell.
  final String defaultShell;

  /// Optional working directory applied when a request does not specify one.
  final String? workingDirectory;

  /// Extra environment overlaid on the inherited environment for every session.
  final Map<String, String> baseEnvironment;

  /// Optional guard; when provided and it returns `false`, the session is
  /// refused (the runtime reports `node.session.rejected`).
  final bool Function(ShellRequest request)? allowCommand;

  /// Creates a process shell backend.
  ProcessShellBackend({
    String? defaultShell,
    this.workingDirectory,
    this.baseEnvironment = const {},
    this.allowCommand,
  }) : defaultShell = defaultShell ?? resolveDefaultShell();

  @override
  Future<ShellSession> start(ShellRequest request) async {
    if (allowCommand != null && !allowCommand!(request)) {
      throw ProcessException(
        request.command ?? defaultShell,
        request.args,
        'Command not permitted by node policy',
      );
    }

    final (executable, args) = resolveShellInvocation(request, defaultShell);
    // Resolve a leading `~` (the client may pass `~/...` as the working dir, e.g.
    // an ephemeral `run`/drive mount path) against the node user's home. On
    // Windows, also translate an MSYS cwd (`/c/...`, as Git Bash reports `$PWD`
    // and as TAB-completion's one-shot exec reuses it) into a Windows path
    // `Process.start` can actually `chdir` into.
    final raw = request.cwd;
    var cwd = raw != null ? expandUserHome(raw) : workingDirectory;
    if (Platform.isWindows && cwd != null && cwd.startsWith('/')) {
      cwd = windowsPathFromMsys(cwd);
    }
    final process = await Process.start(
      executable,
      args,
      workingDirectory: cwd,
      environment: {...baseEnvironment, ..._ptyEnv(request), ...request.env},
      includeParentEnvironment: true,
    );
    return ProcessShellSession(
      process,
      shellFamily: classifyShellFamily(executable),
    );
  }

  /// Without a real PTY the child cannot query its window size via `ioctl`, so
  /// we surface the negotiated geometry through the conventional `TERM`,
  /// `COLUMNS` and `LINES` environment variables. ncurses-based programs (e.g.
  /// `nano`) honour `COLUMNS`/`LINES`, which fixes their *initial* size on this
  /// fallback backend. Explicit [ShellRequest.env] still overrides these.
  Map<String, String> _ptyEnv(ShellRequest request) {
    final pty = request.pty;
    if (pty == null) return const {};
    return {'TERM': pty.term, 'COLUMNS': '${pty.cols}', 'LINES': '${pty.rows}'};
  }
}
