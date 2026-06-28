import '../../protocol/channel.dart';
import 'local_tunnel_bridge.dart';
import 'tunnel_bridge_service.dart';

/// Native factory: the real `dart:io` [TunnelBridgeService].
LocalTunnelBridge localTunnelBridgeFactory({
  required Channel channel,
  required String targetHost,
  required int targetPort,
  required Future<void> Function() onClose,
}) => TunnelBridgeService(
  channel: channel,
  targetHost: targetHost,
  targetPort: targetPort,
  onClose: onClose,
);
