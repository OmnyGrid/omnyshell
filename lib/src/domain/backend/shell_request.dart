import 'package:meta/meta.dart';

import '../entities/session.dart';
import 'pty_spec.dart';
import 'shell_family.dart';

/// A request to start a process or interactive shell on a node.
///
/// Built by the Hub from a client's `session.open` and handed to the node's
/// [ShellBackend]. For [SessionMode.exec] the [command] is required; for
/// [SessionMode.shell] a `null`/empty command launches the node's default
/// login shell.
@immutable
class ShellRequest {
  /// Whether to run a one-shot command or an interactive shell.
  final SessionMode mode;

  /// The command to run (exec mode) or shell to launch (shell mode); `null`
  /// selects the node default.
  final String? command;

  /// Arguments passed to [command].
  final List<String> args;

  /// Extra environment variables for the child process.
  final Map<String, String> env;

  /// Working directory for the child process; `null` uses the node default.
  final String? cwd;

  /// Requested terminal geometry for interactive shells; `null` for exec.
  final PtySpec? pty;

  /// For [SessionMode.exec] only: run the command under this shell family's
  /// interpreter (resolved on the node) instead of the OS default exec shell.
  /// Used so TAB-completion runs in the same family as the interactive session
  /// (notably on Windows, where the default exec shell is always `cmd.exe`).
  /// `null` keeps the default behavior; ignored when explicit [args] are given.
  final ShellFamily? shellFamily;

  /// Creates a shell request.
  const ShellRequest({
    required this.mode,
    this.command,
    this.args = const [],
    this.env = const {},
    this.cwd,
    this.pty,
    this.shellFamily,
  });
}
