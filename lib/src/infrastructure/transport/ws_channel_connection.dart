import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../protocol/frame_codec.dart';
import '../../protocol/omnyshell_connection.dart';
import '../../protocol/omnyshell_frame.dart';

/// An [OmnyShellConnection] over any [WebSocketChannel], with **no** `dart:io`
/// dependency — the browser-safe counterpart of the native `FrameConnection`.
///
/// The native `FrameConnection` rides on omnyhub's `dart:io` WebSocket
/// transport (which builds an `HttpClient` for TLS pinning), poisoning the
/// dart2js build, so the web transport wraps the cross-platform
/// [WebSocketChannel] here instead.
/// Both translate raw text/binary events to and from [OmnyShellFrame]s with a
/// [FrameCodec]; undecodable frames are dropped rather than tearing the
/// connection down.
class WsChannelConnection implements OmnyShellConnection {
  final WebSocketChannel _channel;

  /// The codec used to (de)serialise frames.
  final FrameCodec codec;

  final StreamController<OmnyShellFrame> _incoming =
      StreamController<OmnyShellFrame>();
  final Completer<void> _done = Completer<void>();
  bool _open = true;

  WsChannelConnection._(this._channel, this.codec) {
    _channel.stream.listen(
      (event) {
        try {
          _incoming.add(codec.decode(event as Object));
        } on Object {
          // Drop undecodable frames; do not tear the connection down here.
        }
      },
      onDone: _handleClosed,
      onError: (Object _) => _handleClosed(),
      cancelOnError: false,
    );
  }

  /// Wraps an already-connected [channel].
  factory WsChannelConnection.fromChannel(
    WebSocketChannel channel, {
    FrameCodec? codec,
  }) => WsChannelConnection._(channel, codec ?? FrameCodec.standard());

  @override
  Stream<OmnyShellFrame> get incoming => _incoming.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> get done => _done.future;

  @override
  void send(OmnyShellFrame frame) {
    if (!_open) return;
    _channel.sink.add(codec.encode(frame));
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    await _channel.sink.close(code, reason);
    _handleClosed();
  }

  void _handleClosed() {
    if (!_open && _done.isCompleted) return;
    _open = false;
    if (!_incoming.isClosed) _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }
}
