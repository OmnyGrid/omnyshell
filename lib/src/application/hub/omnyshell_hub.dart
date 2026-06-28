import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tcp_tunnel/tcp_tunnel.dart' show PortRange;

import '../../domain/auth/authenticator.dart';
import '../../domain/auth/authorizer.dart';
import '../../domain/entities/platform_info_io.dart';
import '../../domain/value_objects/omny_uid.dart';
import '../../infrastructure/identity/machine_id.dart';
import '../../infrastructure/identity/spki.dart';
import '../../infrastructure/identity/uid_computer.dart';
import '../../infrastructure/identity/uid_store.dart';
import '../../infrastructure/tls/pem_tls_source.dart';
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

  /// The TLS security context (server certificate + key) for the main `wss`
  /// listener. Exactly one of [securityContext] or [tlsDirectory] must be set;
  /// when [tlsDirectory] drives the listener this is `null`.
  final SecurityContext? securityContext;

  /// A directory holding `fullchain.pem` + `privkey.pem` (LetsEncrypt layout)
  /// for the main `wss` listener. When set, the Hub loads the certificate at
  /// [start] and re-checks the files every [tlsReloadInterval]; on renewal it
  /// re-binds the listener with the fresh context so the new certificate is
  /// served without a restart (briefly running both listeners on the same port
  /// while existing connections drain). Mutually exclusive with
  /// [securityContext].
  final String? tlsDirectory;

  /// How often the Hub re-checks [tlsDirectory] for a renewed certificate. Kept
  /// below a day so a renewal is always picked up within 24h.
  final Duration tlsReloadInterval;

  /// The leaf TLS certificate (PEM or DER bytes) used to derive this hub's
  /// deterministic UID from its public key (SPKI). When omitted the hub runs
  /// without a computed UID.
  final Uint8List? identityCertificate;

  /// Authenticates node and client credentials.
  final Authenticator authenticator;

  /// Authorizes session opens. Defaults to a fail-closed
  /// [RoleBasedAuthorizer].
  final Authorizer authorizer;

  /// How long a node may go silent before being declared offline.
  final Duration heartbeatTimeout;

  /// The public TCP port range tunnels may bind (e.g. `PortRange(20000, 20100)`),
  /// or `null` to disable tunneling (fail closed). Align this with the firewall
  /// rules permitting inbound connections on those ports.
  final PortRange? tunnelPortRange;

  /// The host advertised to clients for tunnel public ports. When empty the
  /// client substitutes the Hub's own hostname (sensible when [host] is a
  /// wildcard bind address).
  final String tunnelPublicHost;

  /// The TLS security context (certificate chain + key) used to terminate TLS
  /// on tunnel public ports requested with `secure: true`. The certificate
  /// should match [tunnelPublicHost]. When `null`, secure tunnels are
  /// unavailable and such requests are rejected.
  ///
  /// Ignored when [tunnelTlsDirectory] is set (the directory then drives a
  /// hot-reloading context instead).
  final SecurityContext? tunnelSecurityContext;

  /// A directory holding `fullchain.pem` + `privkey.pem` (LetsEncrypt layout)
  /// used to terminate TLS on secure tunnel public ports. When set, the Hub
  /// loads the certificate at [start] and re-checks the files every
  /// [tunnelTlsReloadInterval], reloading automatically when they change so
  /// renewals are picked up without a restart. Takes precedence over
  /// [tunnelSecurityContext].
  final String? tunnelTlsDirectory;

  /// How often the Hub re-checks [tunnelTlsDirectory] for a renewed
  /// certificate. Kept below a day so a renewal is always picked up within 24h.
  final Duration tunnelTlsReloadInterval;

  /// The clock (overridable in tests).
  final Clock clock;

  /// Optional diagnostic logger.
  final void Function(String message)? logger;

  /// Creates a hub configuration.
  ///
  /// Provide exactly one of [securityContext] or [tlsDirectory] for the main
  /// listener's TLS.
  HubConfig({
    required this.authenticator,
    this.securityContext,
    this.tlsDirectory,
    this.tlsReloadInterval = const Duration(hours: 12),
    Authorizer? authorizer,
    this.identityCertificate,
    this.host = '0.0.0.0',
    this.port = 8443,
    this.heartbeatTimeout = const Duration(seconds: 30),
    this.tunnelPortRange,
    this.tunnelPublicHost = '',
    this.tunnelSecurityContext,
    this.tunnelTlsDirectory,
    this.tunnelTlsReloadInterval = const Duration(hours: 12),
    this.clock = const SystemClock(),
    this.logger,
  }) : assert(
         (securityContext == null) != (tlsDirectory == null),
         'provide exactly one of securityContext or tlsDirectory',
       ),
       authorizer = authorizer ?? const RoleBasedAuthorizer();
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
  OmnyUid? _uid;
  PemTlsSource? _mainTls;
  PemTlsSource? _tunnelTls;

  /// Creates a hub from [config].
  OmnyShellHub(this.config)
    : broker = HubBroker(
        authenticator: config.authenticator,
        authorizer: config.authorizer,
        clock: config.clock,
        heartbeatTimeout: config.heartbeatTimeout,
        logger: config.logger,
        tunnelPortRange: config.tunnelPortRange,
        tunnelBindHost: config.host,
        tunnelPublicHost: config.tunnelPublicHost,
        tunnelSecurityContext: config.tunnelSecurityContext,
      );

  /// The node registry.
  NodeRegistry get nodes => broker.registry;

  /// The session routing table.
  SessionRouter get sessions => broker.router;

  /// The audit log.
  AuditLog get audit => broker.audit;

  /// This hub's deterministic UID, available after [start] (when an
  /// [HubConfig.identityCertificate] was supplied).
  OmnyUid? get uid => _uid;

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
    await _resolveUid();
    _startTunnelTls();
    broker.start();
    final dir = config.tlsDirectory;
    if (dir != null && dir.isNotEmpty) {
      final source = PemTlsSource(
        dir,
        label: 'hub TLS',
        checkInterval: config.tlsReloadInterval,
        logger: config.logger,
        onReloaded: _rebindMain,
      );
      source.load();
      _mainTls = source;
      _endpoint = await WsServerEndpoint.bind(
        host: config.host,
        port: config.port,
        securityContext: source.context!,
        onConnection: broker.accept,
        shared: true,
      );
      source.start();
    } else {
      _endpoint = await WsServerEndpoint.bind(
        host: config.host,
        port: config.port,
        securityContext: config.securityContext!,
        onConnection: broker.accept,
      );
    }
  }

  /// Re-binds the main listener with a freshly-loaded [ctx] after a certificate
  /// renewal. Binds the new (shared) listener on the currently-bound port, swaps
  /// it in, then closes the old one without forcing — established connections
  /// drain on the old listener while new ones land on the renewed certificate.
  Future<void> _rebindMain(SecurityContext ctx) async {
    final old = _endpoint;
    if (old == null) return;
    try {
      _endpoint = await WsServerEndpoint.bind(
        host: config.host,
        port: old.port,
        securityContext: ctx,
        onConnection: broker.accept,
        shared: true,
      );
      unawaited(old.close(force: false));
      config.logger?.call('hub TLS listener rebound on renewed certificate');
    } on Object catch (e) {
      // Keep serving on the existing listener if the rebind fails.
      _endpoint = old;
      config.logger?.call('hub TLS listener rebind failed: $e');
    }
  }

  /// Loads the tunnel TLS certificate from [HubConfig.tunnelTlsDirectory] and
  /// begins periodic reload checks so renewals are picked up without a restart.
  /// When only a static [HubConfig.tunnelSecurityContext] was supplied the
  /// broker already holds it and there is nothing to reload.
  void _startTunnelTls() {
    final dir = config.tunnelTlsDirectory;
    if (dir == null || dir.isEmpty) return;
    final source = PemTlsSource(
      dir,
      label: 'tunnel TLS',
      checkInterval: config.tunnelTlsReloadInterval,
      logger: config.logger,
      onReloaded: (ctx) => broker.tunnelSecurityContext = ctx,
    );
    source.load();
    broker.tunnelSecurityContext = source.context;
    source.start();
    _tunnelTls = source;
  }

  /// Computes and persists this hub's UID from its TLS public key plus stable
  /// hardware/platform attributes, warning if it changed since the last run.
  /// Best-effort: failure leaves [_uid] null rather than blocking startup.
  Future<void> _resolveUid() async {
    final certBytes = config.identityCertificate;
    if (certBytes == null) return;
    try {
      final keyMaterial =
          CertificateIdentity.spkiFromCertificate(certBytes) ?? certBytes;
      final platform = PlatformInfoLocal.local(agentVersion: 'hub');
      final computed = UidComputer.computeHubUid(
        keyMaterial: keyMaterial,
        machineId: MachineId.read(),
        os: platform.os,
        arch: platform.arch,
        hostname: platform.hostname,
      );
      final resolution = await const UidStore(
        fileName: 'hub.uid',
      ).resolve(computed, logger: config.logger);
      _uid = resolution.uid;
      broker.hubUid = _uid!.value;
    } on Object catch (e) {
      config.logger?.call('hub UID computation failed: $e');
    }
  }

  /// Stops the hub and releases the endpoint.
  Future<void> stop({bool force = true}) async {
    broker.stop();
    _mainTls?.stop();
    _mainTls = null;
    _tunnelTls?.stop();
    _tunnelTls = null;
    await _endpoint?.close(force: force);
    _endpoint = null;
  }
}
