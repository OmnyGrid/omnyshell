import 'dart:async';
import 'dart:typed_data';

import 'control_message.dart';
import 'data_opcode.dart';
import 'frame_codec.dart';
import 'omnyshell_frame.dart';

/// One logical, bidirectional stream multiplexed over a connection.
///
/// A channel carries three byte streams ([stdin], [stdout], [stderr]) plus
/// channel-scoped [control] messages (resize, signal, eof, exit, close,
/// window). Endpoints listen to the streams relevant to their role — a node
/// reads [stdin] and writes stdout/stderr; a client reads [stdout]/[stderr] and
/// writes stdin.
///
/// Outbound data honours a simple credit window for backpressure: a sender may
/// have at most [_credit] unacknowledged bytes outstanding, replenished by the
/// peer's `channel.window` messages. Writes beyond the window are queued and
/// flushed as credit arrives.
class Channel {
  /// The channel id (unique within its connection).
  final int id;

  /// Sends an encoded frame to the peer.
  final void Function(OmnyShellFrame frame) _send;

  // Single-subscription controllers: each stream has exactly one consumer (the
  // node reads stdin/control; the client reads stdout/stderr/control), and they
  // buffer events until that consumer subscribes, so fast early output or an
  // immediate exit is never dropped between channel creation and listen.
  final StreamController<Uint8List> _stdin = StreamController<Uint8List>();
  final StreamController<Uint8List> _stdout = StreamController<Uint8List>();
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>();
  final StreamController<ControlMessage> _control =
      StreamController<ControlMessage>();

  /// Initial / default per-stream send window, in bytes.
  static const int defaultWindow = 256 * 1024;

  final List<_PendingWrite> _outbox = [];
  int _credit = defaultWindow;
  bool _closed = false;

  /// Creates a channel with id [id], sending frames via [send].
  Channel(this.id, void Function(OmnyShellFrame frame) send) : _send = send;

  /// Inbound standard-input bytes (consumed by the node side).
  Stream<Uint8List> get stdin => _stdin.stream;

  /// Inbound standard-output bytes (consumed by the client side).
  Stream<Uint8List> get stdout => _stdout.stream;

  /// Inbound standard-error bytes (consumed by the client side).
  Stream<Uint8List> get stderr => _stderr.stream;

  /// Channel-scoped control messages (resize, signal, eof, exit, close, …).
  Stream<ControlMessage> get control => _control.stream;

  /// Whether the channel has been closed.
  bool get closed => _closed;

  /// Writes [data] to standard input (client → node).
  void sendStdin(List<int> data) => _sendData(DataOpcode.stdin, data);

  /// Writes [data] to standard output (node → client).
  void sendStdout(List<int> data) => _sendData(DataOpcode.stdout, data);

  /// Writes [data] to standard error (node → client).
  void sendStderr(List<int> data) => _sendData(DataOpcode.stderr, data);

  /// Sends a channel-scoped control [message].
  void sendControl(ControlMessage message) {
    if (_closed) return;
    _send(ControlFrame(message));
  }

  void _sendData(DataOpcode opcode, List<int> data) {
    if (_closed || data.isEmpty) return;
    // Split into protocol-sized chunks.
    var offset = 0;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    while (offset < bytes.length) {
      final end = (offset + FrameCodec.maxDataPayload).clamp(0, bytes.length);
      _outbox.add(
        _PendingWrite(opcode, Uint8List.sublistView(bytes, offset, end)),
      );
      offset = end;
    }
    _flush();
  }

  void _flush() {
    while (_outbox.isNotEmpty && _credit >= _outbox.first.bytes.length) {
      final write = _outbox.removeAt(0);
      _credit -= write.bytes.length;
      _send(DataFrame(opcode: write.opcode, channel: id, payload: write.bytes));
    }
  }

  /// Grants [credit] additional outbound bytes (from a `channel.window`), and
  /// flushes any queued writes that now fit.
  void grantCredit(int credit) {
    _credit += credit;
    _flush();
  }

  /// Number of bytes currently queued awaiting send credit.
  int get queuedBytes => _outbox.fold(0, (sum, w) => sum + w.bytes.length);

  // --- Inbound delivery (called by the multiplexer) -------------------------

  /// Delivers an inbound data [frame] to the matching stream.
  void deliverData(DataFrame frame) {
    if (_closed) return;
    switch (frame.opcode) {
      case DataOpcode.stdin:
        _add(_stdin, frame.payload);
      case DataOpcode.stdout:
        _add(_stdout, frame.payload);
      case DataOpcode.stderr:
        _add(_stderr, frame.payload);
    }
  }

  /// Delivers an inbound channel-scoped control [message].
  void deliverControl(ControlMessage message) {
    if (_closed) return;
    if (!_control.isClosed) _control.add(message);
  }

  void _add(StreamController<Uint8List> controller, Uint8List data) {
    if (!controller.isClosed) controller.add(data);
  }

  /// Closes the channel and its streams. Idempotent.
  ///
  /// The per-stream controllers are closed without awaiting their `done`
  /// futures: a single-subscription controller that was never listened to (e.g.
  /// a client's inbound stdin, or a node's inbound stdout) would otherwise block
  /// forever. Any active listener still receives the done event asynchronously.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _outbox.clear();
    unawaited(_stdin.close());
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    unawaited(_control.close());
  }
}

class _PendingWrite {
  final DataOpcode opcode;
  final Uint8List bytes;
  _PendingWrite(this.opcode, this.bytes);
}
