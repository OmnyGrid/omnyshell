import 'dart:io';

import '../../domain/backend/shell_backend.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/backend/shell_session.dart';
import '../../domain/entities/session.dart';
import 'process_shell_session.dart';

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
  }) : defaultShell = defaultShell ?? _resolveDefaultShell();

  @override
  Future<ShellSession> start(ShellRequest request) async {
    if (allowCommand != null && !allowCommand!(request)) {
      throw ProcessException(
        request.command ?? defaultShell,
        request.args,
        'Command not permitted by node policy',
      );
    }

    final (executable, args) = _resolveInvocation(request);
    final process = await Process.start(
      executable,
      args,
      workingDirectory: request.cwd ?? workingDirectory,
      environment: {...baseEnvironment, ...request.env},
      includeParentEnvironment: true,
    );
    return ProcessShellSession(process);
  }

  (String, List<String>) _resolveInvocation(ShellRequest request) {
    final shell = request.mode == SessionMode.shell
        ? (request.command ?? defaultShell)
        : defaultShell;

    if (request.mode == SessionMode.shell) {
      // Interactive shell: launch the shell with any extra args (interactive
      // flag is left to the operator / future PTY backend).
      return (shell, request.args);
    }

    // exec: run the program directly if args were supplied, else via the shell.
    final command = request.command ?? '';
    if (request.args.isNotEmpty) {
      return (command, request.args);
    }
    return (defaultShell, [_shellCommandFlag, command]);
  }

  static String get _shellCommandFlag => Platform.isWindows ? '/c' : '-c';

  static String _resolveDefaultShell() {
    if (Platform.isWindows) {
      return Platform.environment['COMSPEC'] ?? 'cmd.exe';
    }
    final shell = Platform.environment['SHELL'];
    if (shell != null && shell.trim().isNotEmpty) return shell;
    return '/bin/sh';
  }
}
