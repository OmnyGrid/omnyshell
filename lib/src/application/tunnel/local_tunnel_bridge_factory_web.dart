import '../../protocol/channel.dart';
import 'local_tunnel_bridge.dart';

/// Browser stub: the platform cannot dial arbitrary TCP targets, so an `@local`
/// tunnel can never be served from the browser. [connect] reports failure,
/// which makes [ClientRuntime] reply with a `NodeTunnelConnectFailed`.
class _UnsupportedLocalTunnelBridge implements LocalTunnelBridge {
  @override
  Future<bool> connect() async => false;

  @override
  Future<void> close() async {}
}

LocalTunnelBridge localTunnelBridgeFactory({
  required Channel channel,
  required String targetHost,
  required int targetPort,
  required Future<void> Function() onClose,
}) => _UnsupportedLocalTunnelBridge();
