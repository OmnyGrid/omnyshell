import 'package:web_socket_channel/web_socket_channel.dart';

import '../../protocol/omnyshell_connection.dart';
import 'ws_channel_connection.dart';

/// The browser default: opens the platform WebSocket via the cross-platform
/// [WebSocketChannel.connect]. The browser owns the TLS stack, so there are no
/// trust knobs here; `headers` are ignored (unsupported by the browser API —
/// auth is in-band in the OmnyShell handshake).
Future<OmnyShellConnection> defaultConnectionFactory(
  Uri uri, {
  Map<String, String>? headers,
}) async {
  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
  return WsChannelConnection.fromChannel(channel);
}
