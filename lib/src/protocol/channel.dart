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

  /// Completers awaiting the outbox to fully flush (see [outboxDrained]).
  final List<Completer<void>> _drainWaiters = [];

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
  ///
  /// When [onFlushed] is supplied it is invoked as the credit window lets each
  /// chunk of *this* write onto the wire, with the cumulative number of bytes of
  /// [data] flushed so far — a faithful, socket-paced signal for upload progress.
  void sendStdin(List<int> data, {void Function(int sentSoFar)? onFlushed}) =>
      _sendData(DataOpcode.stdin, data, onFlushed: onFlushed);

  /// Writes [data] to standard output (node → client).
  void sendStdout(List<int> data) => _sendData(DataOpcode.stdout, data);

  /// Writes [data] to standard error (node → client).
  void sendStderr(List<int> data) => _sendData(DataOpcode.stderr, data);

  /// Sends a channel-scoped control [message].
  void sendControl(ControlMessage message) {
    if (_closed) return;
    _send(ControlFrame(message));
  }

  void _sendData(
    DataOpcode opcode,
    List<int> data, {
    void Function(int sentSoFar)? onFlushed,
  }) {
    if (_closed || data.isEmpty) return;
    // All chunks of this write share one progress tracker, so [onFlushed] sees a
    // single monotonically increasing count across the whole payload.
    final progress = onFlushed == null
        ? null
        : _WriteProgress(data.length, onFlushed);
    // Split into protocol-sized chunks.
    var offset = 0;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    while (offset < bytes.length) {
      final end = (offset + FrameCodec.maxDataPayload).clamp(0, bytes.length);
      _outbox.add(
        _PendingWrite(
          opcode,
          Uint8List.sublistView(bytes, offset, end),
          progress,
        ),
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
      write.progress?.advance(write.bytes.length);
    }
    if (_outbox.isEmpty) _completeDrainWaiters();
  }

  /// Completes once every queued outbound byte has been flushed to the wire (or
  /// immediately if nothing is queued). A clean close should await this before
  /// calling [close], which clears the outbox — otherwise credit-gated output
  /// still waiting for the peer's window would be silently discarded (truncating
  /// large command output on exit).
  Future<void> get outboxDrained {
    if (_outbox.isEmpty || _closed) return Future<void>.value();
    final completer = Completer<void>();
    _drainWaiters.add(completer);
    return completer.future;
  }

  void _completeDrainWaiters() {
    if (_drainWaiters.isEmpty) return;
    for (final completer in _drainWaiters) {
      if (!completer.isCompleted) completer.complete();
    }
    _drainWaiters.clear();
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
    // Unblock anyone awaiting the (now-discarded) outbox so they don't hang.
    _completeDrainWaiters();
    unawaited(_stdin.close());
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    unawaited(_control.close());
  }
}

class _PendingWrite {
  final DataOpcode opcode;
  final Uint8List bytes;

  /// Progress tracker shared by all chunks of one [Channel.sendStdin] write, or
  /// null when the caller asked for no progress.
  final _WriteProgress? progress;
  _PendingWrite(this.opcode, this.bytes, this.progress);
}

/// Accumulates the bytes of a single write as its chunks reach the wire and
/// reports the running total to the caller's `onFlushed`.
class _WriteProgress {
  final int total;
  final void Function(int sentSoFar) _onFlushed;
  int _sent = 0;
  _WriteProgress(this.total, this._onFlushed);

  void advance(int chunkBytes) {
    _sent += chunkBytes;
    _onFlushed(_sent);
  }
}
