import 'dart:typed_data';

import '../../domain/backend/shell_family.dart';
import '../../domain/backend/shell_session.dart';
import '../../domain/value_objects/session_id.dart';
import 'shell_session_port.dart';

/// Adapts a node-side [ShellSession] to the transport-free [ShellSessionPort]
/// the interactive terminal UI drives.
///
/// This is the seam that lets `omnyshell local` run the interactive shell
/// entirely on this machine: the same [InteractiveShellController]/[LineEditor]
/// stack that normally talks to a [RemoteSession] over the wire is pointed at a
/// shell started by a local [ShellBackend] instead. No Hub, Node, protocol or
/// TLS is involved.
///
/// Most of the surface passes straight through. The transport-only operations
/// have no meaning locally: [grantWindow] (send-window flow control) is a no-op,
/// and [detach] is unsupported (there is no node to keep the shell alive), so
/// [wasDetached] is always `false`.
class LocalShellSession implements ShellSessionPort {
  final ShellSession _shell;
  final SessionId _id;

  /// Wraps [shell], minting a stable local session [id] used only as the
  /// cwd-marker nonce by the controller.
  LocalShellSession(this._shell, {SessionId? id})
    : _id = id ?? SessionId.generate();

  @override
  Stream<Uint8List> get stdout => _shell.stdout;

  @override
  Stream<Uint8List> get stderr => _shell.stderr;

  @override
  Future<int> get exitCode => _shell.exitCode;

  @override
  ShellFamily get shellFamily => _shell.shellFamily;

  @override
  SessionId? get id => _id;

  @override
  bool get wasDetached => false;

  @override
  void writeStdin(List<int> data) => _shell.writeStdin(data);

  @override
  void resize({required int cols, required int rows}) =>
      _shell.resize(cols: cols, rows: rows);

  /// No-op locally: send-window flow control only matters over a network
  /// transport.
  @override
  void grantWindow(int credit) {}

  @override
  void interrupt() => _shell.sendSignal('SIGINT');

  /// Unsupported locally — there is no node to keep the shell alive, so a detach
  /// request is ignored (the caller falls back to closing the session).
  @override
  Future<void> detach() async {}

  @override
  Future<void> close() => _shell.kill();

  /// Half-closes the shell's standard input (Ctrl-D), letting it exit with its
  /// own status instead of being killed. Not part of [ShellSessionPort]; the
  /// local host holds the concrete type and calls this from the editor's EOF
  /// handler.
  Future<void> closeStdin() => _shell.closeStdin();
}
