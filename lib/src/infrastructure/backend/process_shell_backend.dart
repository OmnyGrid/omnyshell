import 'dart:io';

import '../../domain/backend/shell_backend.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/backend/shell_session.dart';
import '../../shared/utils/omnyshell_home.dart';
import '../../shared/utils/pub_cache_bin.dart';
import 'live_environment.dart';
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

  /// When set, supplies the extra environment per session instead of
  /// [baseEnvironment], given the environment the session inherits (e.g. a
  /// `LiveNodeProfile`, so profile edits apply without a restart).
  final Map<String, String> Function(Map<String, String> inherited)?
  baseEnvironmentFor;

  /// Optional guard; when provided and it returns `false`, the session is
  /// refused (the runtime reports `node.session.rejected`).
  final bool Function(ShellRequest request)? allowCommand;

  /// Creates a process shell backend.
  ProcessShellBackend({
    String? defaultShell,
    this.workingDirectory,
    this.baseEnvironment = const {},
    this.baseEnvironmentFor,
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

    // On Windows, the system and user variables as the registry holds them
    // now, not as they were when the node started (see `live_environment`).
    final live = liveProcessEnvironment();
    final base = baseEnvironmentFor?.call(live) ?? baseEnvironment;
    final (executable, args) = resolveShellInvocation(
      request,
      defaultShell,
      environment: live,
    );
    // Client's choice, then the node's, then the user's home (a profile `HOME`
    // first) — and only then wherever this process happens to be standing.
    // See `resolveStartDirectory`.
    final cwd = resolveStartDirectory(
      requested: request.cwd,
      configured: workingDirectory,
      environment: {...live, ...base},
    );
    final process = await Process.start(
      executable,
      args,
      workingDirectory: cwd,
      // `withUserHome` only fills in `HOME` when neither this process nor the
      // request supplies one — a node run as a service is handed no `HOME`, and
      // a shell without one is subtly broken rather than obviously so.
      // `withPubCacheBin` does the same for the pub cache `bin` directory, so
      // `dart pub global activate`-installed CLIs (`omnyshell` among them) are
      // runnable in a session that sources no rc. The inherited environment is
      // overlaid with whatever the registry has changed since ([live]), so
      // both helpers judge what the child will actually see.
      environment: withPubCacheBin(
        withUserHome({
          ...refreshedVariables(live),
          ...base,
          ..._ptyEnv(request),
          ...request.env,
        }, processEnvironment: live),
        processEnvironment: live,
      ),
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
