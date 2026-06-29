/// OmnyShell Hub: run a Hub that authenticates principals, registers nodes, and
/// brokers secure sessions.
///
/// ```dart
/// final hub = OmnyShellHub(HubConfig(
///   securityContext: context,
///   authenticator: authenticator,
/// ));
/// await hub.start();
/// ```
library;

export 'omnyshell.dart';

// Re-exported so Hub operators can configure HubConfig.tunnelPortRange without a
// direct dependency on the tcp_tunnel package.
export 'package:tcp_tunnel/tcp_tunnel.dart' show PortRange;

// AI config, so operators can wire `HubConfig.aiConfig: AiConfigIo.load()` to
// let the Hub proxy AI requests (with the key injected Hub-side) for browser
// clients that cannot reach provider APIs directly.
export 'src/application/ai/ai_config.dart';
export 'src/application/ai/ai_config_io.dart'
    show AiConfigIo, AiConfigDescription;
export 'src/application/hub/audit_log.dart';
export 'src/application/hub/heartbeat_monitor.dart';
export 'src/application/hub/http_proxy_service.dart';
export 'src/application/hub/hub_broker.dart';
export 'src/application/hub/node_registry.dart';
export 'src/application/hub/omnyshell_hub.dart';
export 'src/application/hub/session_router.dart';
export 'src/application/hub/tunnel_registry.dart';
export 'src/infrastructure/auth/authorized_keys_store.dart';
export 'src/infrastructure/auth/composite_authenticator.dart';
export 'src/infrastructure/auth/public_key_authenticator.dart';
export 'src/infrastructure/auth/token_authenticator.dart';
export 'src/infrastructure/transport/ws_server_endpoint.dart';
