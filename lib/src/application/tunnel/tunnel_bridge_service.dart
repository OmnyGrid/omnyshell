import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../protocol/channel.dart';
import '../../protocol/control_message.dart';
import 'local_tunnel_bridge.dart';

/// Bridges one external TCP connection (held by the Hub) to an internal target
/// socket, piping bytes over [channel]. Runs on the exposer side — a node or the
/// client's own machine — for `tunnel`-mode connections.
///
/// Direction convention (matching the Hub): bytes arriving as the channel's
/// **stdin** came from the external consumer and are written to the target;
/// bytes read from the target are sent as **stdout** to the external consumer.
///
/// Flow control reuses the channel's credit window. Inbound stdin is matched by
/// granting the Hub fresh stdin credit as it is written to the target; outbound
/// stdout is credit-gated by the channel, and the target read is paused when the
/// outbound queue grows past [_highWater] (the Hub replenishes stdout credit as
/// it drains to the external socket). On target close, the bridge waits for the
/// outbound queue to fully drain before closing so responses are never
/// truncated.
class TunnelBridgeService implements LocalTunnelBridge {
  /// The adopted channel toward the Hub.
  final Channel channel;

  /// The internal host to dial.
  final String targetHost;

  /// The internal TCP port to dial.
  final int targetPort;

  /// Called once the bridge has fully torn down so the runtime can forget it.
  final Future<void> Function() onClose;

  /// Diagnostic logger.
  final void Function(String message)? log;

  /// Queued-outbound high-water mark before pausing the target read.
  static const int _highWater = Channel.defaultWindow;

  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  StreamSubscription<Uint8List>? _stdinSub;
  StreamSubscription<ControlMessage>? _controlSub;
  bool _closed = false;
  bool _targetClosed = false;

  /// Creates a tunnel bridge service.
  TunnelBridgeService({
    required this.channel,
    required this.targetHost,
    required this.targetPort,
    required this.onClose,
    this.log,
  });

  /// Dials the target. Returns `true` and starts piping on success, or `false`
  /// (without starting) if the dial fails.
  @override
  Future<bool> connect() async {
    final Socket socket;
    try {
      socket = await Socket.connect(targetHost, targetPort);
    } on Object catch (e) {
      log?.call('[tunnel] dial $targetHost:$targetPort failed: $e');
      return false;
    }
    _socket = socket;
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // Best-effort; not all platforms honour the option.
    }

    // external -> target: write channel stdin to the target socket, granting
    // the Hub fresh stdin credit as we consume it.
    _stdinSub = channel.stdin.listen((data) {
      if (_closed) return;
      socket.add(data);
      channel.sendControl(
        ChannelWindow(
          channel: channel.id,
          stream: 'stdin',
          credit: data.length,
        ),
      );
    }, onError: (Object _) => unawaited(_teardown('stdin_error')));

    // target -> external: send target bytes as stdout, pausing the target read
    // when the outbound queue grows past the high-water mark.
    _socketSub = socket.listen(
      (data) {
        if (_closed) return;
        channel.sendStdout(data);
        if (channel.queuedBytes >= _highWater) _socketSub?.pause();
      },
      onDone: _onTargetClosed,
      onError: (Object _) => unawaited(_teardown('target_error')),
      cancelOnError: false,
    );

    _controlSub = channel.control.listen((m) {
      if (m is ChannelClose) {
        // The Hub closed (external consumer gone); drop our side silently.
        unawaited(_teardown('peer_closed', notifyPeer: false));
      } else if (m is ChannelWindow && m.stream == 'stdout') {
        // The Hub drained to the external socket and replenished credit.
        if (_targetClosed) {
          _maybeFinishAfterDrain();
        } else if ((_socketSub?.isPaused ?? false) &&
            channel.queuedBytes < _highWater) {
          _socketSub?.resume();
        }
      }
    });
    return true;
  }

  void _onTargetClosed() {
    if (_closed || _targetClosed) return;
    _targetClosed = true;
    _maybeFinishAfterDrain();
  }

  /// Closes once all credit-gated outbound bytes have been flushed to the Hub,
  /// so the response is not truncated. If the Hub stops granting credit it will
  /// instead close the channel, which tears us down via the control listener.
  void _maybeFinishAfterDrain() {
    if (_closed || !_targetClosed) return;
    if (channel.queuedBytes == 0) {
      unawaited(_teardown('target_closed'));
    }
  }

  Future<void> _teardown(String reason, {bool notifyPeer = true}) async {
    if (_closed) return;
    _closed = true;
    if (notifyPeer) {
      channel.sendControl(ChannelClose(channel: channel.id, reason: reason));
    }
    await _stdinSub?.cancel();
    await _socketSub?.cancel();
    await _controlSub?.cancel();
    _socket?.destroy();
    _socket = null;
    await onClose();
  }

  /// Closes the bridge and its target socket (used on exposer shutdown).
  @override
  Future<void> close() => _teardown('exposer_closed');
}
