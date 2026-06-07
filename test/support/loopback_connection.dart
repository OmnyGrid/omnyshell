import 'dart:async';

import 'package:omnyshell/omnyshell.dart';

/// An in-memory [OmnyShellConnection] for unit-testing protocol code without a
/// real socket.
///
/// [send] records frames in [sent]; [deliver] simulates an inbound frame. Use
/// [LoopbackConnection.pair] to wire two ends back-to-back so that whatever one
/// side sends the other receives (after a codec round-trip is *not* performed —
/// frames are passed by reference, which is sufficient for routing tests).
class LoopbackConnection implements OmnyShellConnection {
  final StreamController<OmnyShellFrame> _incoming =
      StreamController<OmnyShellFrame>();
  final List<OmnyShellFrame> sent = [];
  final Completer<void> _done = Completer<void>();
  void Function(OmnyShellFrame frame)? _peerSink;
  bool _open = true;

  /// Creates a standalone loopback connection.
  LoopbackConnection();

  /// Creates two connections wired to each other.
  static (LoopbackConnection, LoopbackConnection) pair() {
    final a = LoopbackConnection();
    final b = LoopbackConnection();
    a._peerSink = b._incoming.add;
    b._peerSink = a._incoming.add;
    return (a, b);
  }

  @override
  Stream<OmnyShellFrame> get incoming => _incoming.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> get done => _done.future;

  @override
  void send(OmnyShellFrame frame) {
    sent.add(frame);
    _peerSink?.call(frame);
  }

  /// Simulates an inbound frame arriving from the peer (standalone mode).
  void deliver(OmnyShellFrame frame) => _incoming.add(frame);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    if (!_incoming.isClosed) await _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }
}
