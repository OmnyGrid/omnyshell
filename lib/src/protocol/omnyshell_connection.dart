import 'omnyshell_frame.dart';

/// A duplex, frame-oriented link between two OmnyShell peers.
///
/// This is the transport *port*: the protocol and runtimes depend only on this
/// abstraction, while the concrete WebSocket-on-TLS adapter
/// (`WebSocketConnection`) lives in the infrastructure layer. Every frame is an
/// already-decoded [OmnyShellFrame]; the connection owns the [FrameCodec].
abstract class OmnyShellConnection {
  /// Inbound frames decoded from the peer. A single-subscription stream; it
  /// closes when the connection closes.
  Stream<OmnyShellFrame> get incoming;

  /// Whether the connection is currently open.
  bool get isOpen;

  /// Completes when the connection has fully closed.
  Future<void> get done;

  /// Sends [frame] to the peer. Silently dropped if the connection is closed.
  void send(OmnyShellFrame frame);

  /// Closes the connection, optionally with a WebSocket [code]/[reason].
  Future<void> close([int? code, String? reason]);
}
