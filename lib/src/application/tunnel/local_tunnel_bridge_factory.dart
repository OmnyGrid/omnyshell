/// Resolves the platform-default [LocalTunnelBridgeFactory]: the real
/// `dart:io` TCP bridge on the VM, an inert stub in the browser (where dialing
/// arbitrary TCP targets is impossible).
library;

export 'local_tunnel_bridge.dart';
export 'local_tunnel_bridge_factory_io.dart'
    if (dart.library.js_interop) 'local_tunnel_bridge_factory_web.dart';
