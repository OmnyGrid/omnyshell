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
  }) : defaultShell = defaultShell ?? resolveDefaultShell() {
    // The registry as it is at node start: the baseline that tells what the
    // node's launcher set from what it inherited (see `live_environment`).
    primeLiveEnvironment();
  }

  @override
  Future<ShellSession> start(ShellRequest request) {
    // On Windows, the system and user variables as the registry holds them
    // now, not as they were when the node started (see `live_environment`),
    // with the node's profile over them.
    final live = liveProcessEnvironment();
    return startWithNodeEnvironment(
      request,
      mergeEnvironment([
        live,
        baseEnvironmentFor?.call(live) ?? baseEnvironment,
      ]),
    );
  }

  /// [start], given the node side of the session's environment — the live
  /// environment with the profile over it — already computed (by a decorating
  /// backend falling back to this one), so it is not read a second time.
  Future<ShellSession> startWithNodeEnvironment(
    ShellRequest request,
    Map<String, String> nodeEnvironment,
  ) async {
    if (allowCommand != null && !allowCommand!(request)) {
      throw ProcessException(
        request.command ?? defaultShell,
        request.args,
        'Command not permitted by node policy',
      );
    }

    // The shell and the start directory are the node's choices, so they are
    // looked up in the node's environment only: a client-sent `PATH` in
    // [ShellRequest.env] must not pick which `bash.exe` the node probes and
    // runs (a node policy vets the request's command, not its environment).
    final (executable, args) = resolveShellInvocation(
      request,
      defaultShell,
      environment: nodeEnvironment,
    );
    // Client's choice, then the node's, then the user's home (a profile `HOME`
    // first) — and only then wherever this process happens to be standing.
    // See `resolveStartDirectory`.
    final cwd = resolveStartDirectory(
      requested: request.cwd,
      configured: workingDirectory,
      environment: nodeEnvironment,
    );
    // The session's whole environment, built here rather than merged with
    // this process's by `Process.start`: that merge matches names by exact
    // case, so a profile `PATH` next to the inherited `Path` reached the child
    // as two variables, the first (stale) one winning.
    final env = mergeEnvironment([
      nodeEnvironment,
      _ptyEnv(request),
      request.env,
    ]);
    final process = await Process.start(
      executable,
      args,
      workingDirectory: cwd,
      // `withUserHome` only fills in `HOME` when nothing supplies one — a node
      // run as a service is handed no `HOME`, and a shell without one is
      // subtly broken rather than obviously so. `withPubCacheBin` does the same
      // for the pub cache `bin` directory, so `dart pub global
      // activate`-installed CLIs (`omnyshell` among them) are runnable in a
      // session that sources no rc. [env] is complete, so it is also what
      // both consult instead of this process's environment.
      environment: mergeEnvironment([
        withPubCacheBin(
          withUserHome(env, processEnvironment: env),
          processEnvironment: env,
        ),
      ]),
      includeParentEnvironment: false,
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
