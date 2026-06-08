import 'dart:io';

import '../../domain/backend/shell_request.dart';
import '../../domain/entities/session.dart';

/// Resolves how a [ShellRequest] maps to an executable and arguments, shared by
/// the pipe-based and PTY-based backends so both honour the same rules:
///
/// - **shell** mode launches the request's shell (or [defaultShell]) with any
///   extra args.
/// - **exec** mode runs the program directly when [ShellRequest.args] are given,
///   otherwise via `<shell> -c "<command>"` so a full command line works.
(String, List<String>) resolveShellInvocation(
  ShellRequest request,
  String defaultShell,
) {
  if (request.mode == SessionMode.shell) {
    // Interactive shell: launch the shell with any extra args.
    return (request.command ?? defaultShell, request.args);
  }

  // exec: run the program directly if args were supplied, else via the shell.
  final command = request.command ?? '';
  if (request.args.isNotEmpty) {
    return (command, request.args);
  }
  return (defaultShell, [shellCommandFlag, command]);
}

/// The flag a shell uses to run a single command string (`-c`, `/c` on Windows).
String get shellCommandFlag => Platform.isWindows ? '/c' : '-c';

/// Resolves the node's default shell from the environment: `$SHELL` on POSIX,
/// `%COMSPEC%`/`cmd.exe` on Windows.
String resolveDefaultShell() {
  if (Platform.isWindows) {
    return Platform.environment['COMSPEC'] ?? 'cmd.exe';
  }
  final shell = Platform.environment['SHELL'];
  if (shell != null && shell.trim().isNotEmpty) return shell;
  return '/bin/sh';
}
