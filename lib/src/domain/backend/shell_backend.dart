import 'shell_request.dart';
import 'shell_session.dart';

/// Starts [ShellSession]s on a node in response to authorized session opens.
///
/// This is the seam that decouples session execution from the protocol. Stage 1
/// ships a `ProcessShellBackend` (pipe-based `Process.start`); a real PTY
/// backend can be substituted without touching the runtime or protocol.
abstract class ShellBackend {
  /// Starts a session for [request], returning a live [ShellSession].
  ///
  /// May throw if the command is invalid or the node is at capacity; the node
  /// runtime translates failures into a `node.session.rejected` message.
  Future<ShellSession> start(ShellRequest request);
}
