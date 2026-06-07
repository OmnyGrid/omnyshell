import 'dart:async';

import 'channel.dart';
import 'control_message.dart';
import 'omnyshell_connection.dart';
import 'omnyshell_frame.dart';

/// Multiplexes logical [Channel]s over a single [OmnyShellConnection].
///
/// Inbound frames are dispatched to their channel by id; data and channel-scoped
/// control reach the matching [Channel], while `channel.window` messages
/// replenish that channel's send credit. Frames that target no live channel
/// (connection-level control such as `hello`, `auth.*`, `node.*`, `ping`, and
/// channel-scoped frames whose channel has not yet been created locally — e.g.
/// `session.open` arriving at the Hub-facing side) surface on [control] so the
/// runtime can act on them and create/adopt channels.
///
/// Used by the Node and Client runtimes; the Hub relays at the raw-frame level
/// instead (it rewrites channel ids without materialising [Channel]s).
class ChannelMultiplexer {
  /// The underlying connection.
  final OmnyShellConnection connection;

  final Map<int, Channel> _channels = {};
  final StreamController<ControlMessage> _control =
      StreamController<ControlMessage>.broadcast();
  late final StreamSubscription<OmnyShellFrame> _sub;
  int _nextId;
  bool _disposed = false;

  /// Creates a multiplexer over [connection].
  ///
  /// [firstChannelId] is the first id [open] hands out (must be ≥ 1; `0` is the
  /// reserved control channel).
  ChannelMultiplexer(this.connection, {int firstChannelId = 1})
    : _nextId = firstChannelId {
    _sub = connection.incoming.listen(
      _dispatch,
      onDone: _onDone,
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  /// Control messages not delivered to a live channel.
  Stream<ControlMessage> get control => _control.stream;

  /// The currently-open channels.
  Iterable<Channel> get channels => _channels.values;

  /// Allocates a fresh channel id and creates a [Channel] for it (the local
  /// side is the opener).
  Channel open() {
    final id = _nextId++;
    return _create(id);
  }

  /// Creates a [Channel] for an id chosen by the peer (the local side serves a
  /// peer-opened channel).
  ///
  /// Throws [StateError] if a channel with [id] already exists.
  Channel adopt(int id) {
    if (_channels.containsKey(id)) {
      throw StateError('Channel $id already exists');
    }
    return _create(id);
  }

  /// The channel with [id], or `null` if none is open.
  Channel? channel(int id) => _channels[id];

  Channel _create(int id) {
    final ch = Channel(id, connection.send);
    _channels[id] = ch;
    return ch;
  }

  /// Closes and forgets the channel with [id].
  Future<void> closeChannel(int id) async {
    final ch = _channels.remove(id);
    if (ch != null) await ch.close();
  }

  /// Pauses inbound delivery (per-hop backpressure).
  void pause() => _sub.pause();

  /// Resumes inbound delivery.
  void resume() {
    if (_sub.isPaused) _sub.resume();
  }

  void _dispatch(OmnyShellFrame frame) {
    final cid = frame.channelId;
    final channel = (cid != null && cid != 0) ? _channels[cid] : null;
    if (channel != null) {
      switch (frame) {
        case final DataFrame f:
          channel.deliverData(f);
        case ControlFrame(message: final m):
          if (m is ChannelWindow) channel.grantCredit(m.credit);
          channel.deliverControl(m);
      }
      return;
    }
    // Unrouted: only control frames are meaningful to the runtime.
    if (frame is ControlFrame && !_control.isClosed) {
      _control.add(frame.message);
    }
  }

  void _onDone() {
    if (!_control.isClosed) _control.close();
  }

  /// Closes all channels and stops dispatching. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub.cancel();
    final open = _channels.values.toList();
    _channels.clear();
    for (final ch in open) {
      await ch.close();
    }
    if (!_control.isClosed) await _control.close();
  }
}
