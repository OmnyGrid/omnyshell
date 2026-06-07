import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../protocol/frame_codec.dart';
import '../../protocol/omnyshell_connection.dart';
import '../../protocol/omnyshell_frame.dart';

/// An [OmnyShellConnection] over a WebSocket (carried on TLS for `wss://`).
///
/// Wraps a [WebSocketChannel], translating raw text/binary events to and from
/// [OmnyShellFrame]s with a [FrameCodec]. Undecodable frames are dropped rather
/// than crashing the peer; protocol-level validation and fail-closed behaviour
/// live in the runtimes.
class WebSocketConnection implements OmnyShellConnection {
  final WebSocketChannel _channel;

  /// The codec used to (de)serialise frames.
  final FrameCodec codec;

  final StreamController<OmnyShellFrame> _incoming =
      StreamController<OmnyShellFrame>();
  final Completer<void> _done = Completer<void>();
  bool _open = true;

  WebSocketConnection._(this._channel, this.codec) {
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

  /// Wraps an already-upgraded WebSocket channel (Hub server side).
  factory WebSocketConnection.fromChannel(
    WebSocketChannel channel, {
    FrameCodec? codec,
  }) => WebSocketConnection._(channel, codec ?? FrameCodec.standard());

  /// Dials [uri] (a `wss://` URL) and returns a connected
  /// [WebSocketConnection].
  ///
  /// [headers] are sent on the upgrade request. [securityContext] supplies the
  /// trust roots for TLS; for tests against a self-signed certificate, provide
  /// a context that trusts it. [onBadCertificate] is an escape hatch for
  /// certificate pinning or self-signed test certificates — when `null` (the
  /// default) standard verification applies and untrusted certificates are
  /// rejected. The connection is established before returning.
  static Future<WebSocketConnection> connect(
    Uri uri, {
    Map<String, dynamic>? headers,
    FrameCodec? codec,
    SecurityContext? securityContext,
    Duration? pingInterval,
    bool Function(X509Certificate cert, String host, int port)?
    onBadCertificate,
  }) async {
    final httpClient = HttpClient(context: securityContext);
    if (onBadCertificate != null) {
      httpClient.badCertificateCallback = onBadCertificate;
    }
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: headers,
      pingInterval: pingInterval,
      customClient: httpClient,
    );
    await channel.ready;
    return WebSocketConnection._(channel, codec ?? FrameCodec.standard());
  }

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
