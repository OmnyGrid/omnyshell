import 'dart:async';
import 'dart:io';

import '../../domain/auth/authenticator.dart';
import '../../domain/auth/authorizer.dart';
import '../../infrastructure/transport/ws_server_endpoint.dart';
import '../../shared/utils/clock.dart';
import 'audit_log.dart';
import 'hub_broker.dart';
import 'node_registry.dart';
import 'session_router.dart';

/// Configuration for an [OmnyShellHub].
class HubConfig {
  /// The bind address (a [String] host or an [InternetAddress]).
  final Object host;

  /// The TCP port to listen on (`0` binds an ephemeral port).
  final int port;

  /// The mandatory TLS security context (server certificate + key).
  final SecurityContext securityContext;

  /// Authenticates node and client credentials.
  final Authenticator authenticator;

  /// Authorizes session opens. Defaults to a fail-closed
  /// [RoleBasedAuthorizer].
  final Authorizer authorizer;

  /// How long a node may go silent before being declared offline.
  final Duration heartbeatTimeout;

  /// The clock (overridable in tests).
  final Clock clock;

  /// Optional diagnostic logger.
  final void Function(String message)? logger;

  /// Creates a hub configuration.
  HubConfig({
    required this.securityContext,
    required this.authenticator,
    Authorizer? authorizer,
    this.host = '0.0.0.0',
    this.port = 8443,
    this.heartbeatTimeout = const Duration(seconds: 30),
    this.clock = const SystemClock(),
    this.logger,
  }) : authorizer = authorizer ?? const RoleBasedAuthorizer();
}

/// An embeddable OmnyShell Hub: a TLS WebSocket endpoint wired to a
/// [HubBroker].
///
/// ```dart
/// final hub = OmnyShellHub(config);
/// await hub.start();
/// ```
class OmnyShellHub {
  /// The hub configuration.
  final HubConfig config;

  /// The broker that authenticates, authorizes and relays.
  final HubBroker broker;

  WsServerEndpoint? _endpoint;

  /// Creates a hub from [config].
  OmnyShellHub(this.config)
    : broker = HubBroker(
        authenticator: config.authenticator,
        authorizer: config.authorizer,
        clock: config.clock,
        heartbeatTimeout: config.heartbeatTimeout,
        logger: config.logger,
      );

  /// The node registry.
  NodeRegistry get nodes => broker.registry;

  /// The session routing table.
  SessionRouter get sessions => broker.router;

  /// The audit log.
  AuditLog get audit => broker.audit;

  /// The port the hub is listening on (valid after [start]).
  int get port => _endpoint?.port ?? config.port;

  /// Whether the hub is running.
  bool get isRunning => _endpoint != null;

  /// A point-in-time snapshot of hub metrics.
  Map<String, dynamic> metrics() => {
    'nodes': nodes.all.length,
    'onlineNodes': nodes.all.where((n) => n.descriptor.online).length,
    'activeSessions': sessions.all.length,
    'auditRecords': audit.records.length,
  };

  /// Binds the TLS endpoint and starts the liveness watchdog.
  Future<void> start() async {
    if (_endpoint != null) return;
    broker.start();
    _endpoint = await WsServerEndpoint.bind(
      host: config.host,
      port: config.port,
      securityContext: config.securityContext,
      onConnection: broker.accept,
    );
  }

  /// Stops the hub and releases the endpoint.
  Future<void> stop({bool force = true}) async {
    broker.stop();
    await _endpoint?.close(force: force);
    _endpoint = null;
  }
}
