import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';

import '../../protocol/frame_codec.dart';
import 'web_socket_connection.dart';

/// Called for every accepted WebSocket connection.
typedef OnConnection = void Function(WebSocketConnection connection);

/// A Hub-side TLS WebSocket listener.
///
/// Binds an HTTPS server with the provided [SecurityContext] and upgrades
/// incoming WebSocket requests, handing each accepted [WebSocketConnection] to
/// the supplied [OnConnection] callback. There is no plaintext mode: a
/// [SecurityContext] is mandatory.
class WsServerEndpoint {
  final HttpServer _server;

  WsServerEndpoint._(this._server);

  /// The address the server is bound to.
  InternetAddress get address => _server.address;

  /// The port the server is listening on.
  int get port => _server.port;

  /// Binds and starts a TLS WebSocket endpoint on [host]:[port].
  ///
  /// [securityContext] must provide the server certificate chain and private
  /// key. [onConnection] receives every accepted connection. Pass `port: 0` to
  /// bind an ephemeral port (useful in tests); read [port] afterwards.
  ///
  /// With [shared] true, multiple servers may bind the same address/port and
  /// incoming connections are distributed among them. The Hub uses this when
  /// the listener certificate is hot-reloadable: on renewal it binds a fresh
  /// listener on the same port before draining the old one, so the swap happens
  /// without a gap or a port-in-use race.
  static Future<WsServerEndpoint> bind({
    required Object host,
    required int port,
    required SecurityContext securityContext,
    required OnConnection onConnection,
    FrameCodec Function()? codecFactory,
    bool shared = false,
  }) async {
    final handler = webSocketHandler((channel, _) {
      onConnection(
        WebSocketConnection.fromChannel(
          channel,
          codec: codecFactory?.call() ?? FrameCodec.standard(),
        ),
      );
    });

    final server = await shelf_io.serve(
      const Pipeline().addHandler(handler),
      host,
      port,
      securityContext: securityContext,
      shared: shared,
    );
    return WsServerEndpoint._(server);
  }

  /// Stops the server. With [force], open connections are dropped immediately.
  Future<void> close({bool force = false}) => _server.close(force: force);
}
