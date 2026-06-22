import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:omnyshell/omnyshell_node.dart';

/// Test fixtures and a small cluster harness for OmnyShell integration/e2e
/// tests over real `wss` loopback connections using a self-signed certificate.

/// A [Clock] that returns a fixed, advanceable instant for deterministic tests.
class FixedClock implements Clock {
  DateTime _now;

  /// Creates a fixed clock at [start] (defaults to a stable epoch).
  FixedClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 1, 1);

  /// Advances the clock by [delta].
  void advance(Duration delta) => _now = _now.add(delta);

  @override
  DateTime now() => _now;
}

/// Resolves a path under `test/support/certs`, relative to the package root.
String _certPath(String name) {
  for (final base in ['test/support/certs', 'support/certs', 'certs']) {
    final candidate = File('$base/$name');
    if (candidate.existsSync()) return candidate.path;
  }
  return 'test/support/certs/$name';
}

/// The Hub's TLS context (server certificate + key).
SecurityContext hubSecurityContext() => SecurityContext()
  ..useCertificateChain(_certPath('localhost.crt'))
  ..usePrivateKey(_certPath('localhost.key'));

/// A client/node TLS context that trusts the test certificate.
SecurityContext trustContext() =>
    SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificates(_certPath('localhost.crt'));

/// A running Hub + helpers to attach nodes and clients over `wss`.
class TestCluster {
  /// The running hub.
  final OmnyShellHub hub;

  /// Token grants recognised by the hub (token → grant).
  final Map<String, TokenGrant> tokens;

  final List<NodeRuntime> _nodes = [];
  final List<ClientRuntime> _clients = [];

  TestCluster._(this.hub, this.tokens);

  /// The `wss` URL of the hub.
  Uri get hubUri => Uri.parse('wss://127.0.0.1:${hub.port}');

  /// Starts a hub on an ephemeral port with the given [tokens] (defaulting to
  /// an admin node token, an admin user token and a limited developer token),
  /// and an optional [authorizer]/[clock].
  static Future<TestCluster> start({
    Map<String, TokenGrant>? tokens,
    Authorizer? authorizer,
    Clock? clock,
    Duration heartbeatTimeout = const Duration(seconds: 30),
    PortRange? tunnelPortRange,
    SecurityContext? tunnelSecurityContext,
  }) async {
    final grants =
        tokens ??
        {
          'node-token': TokenGrant(
            principal: PrincipalId('node-account'),
            roles: {'node'},
          ),
          'admin-token': TokenGrant(
            principal: PrincipalId('alice'),
            displayName: 'Alice',
            roles: {'admin'},
          ),
          'dev-token': TokenGrant(
            principal: PrincipalId('dev'),
            displayName: 'Dev',
            roles: {'developer'},
          ),
        };
    final hub = OmnyShellHub(
      HubConfig(
        host: '127.0.0.1',
        port: 0,
        securityContext: hubSecurityContext(),
        authenticator: TokenAuthenticator(grants),
        authorizer: authorizer,
        heartbeatTimeout: heartbeatTimeout,
        tunnelPortRange: tunnelPortRange,
        tunnelSecurityContext: tunnelSecurityContext,
        clock: clock ?? const SystemClock(),
      ),
    );
    await hub.start();
    return TestCluster._(hub, grants);
  }

  /// Connects a node to the hub and waits until it is serving.
  Future<NodeRuntime> startNode({
    required String id,
    String token = 'node-token',
    String principal = 'node-account',
    Map<String, String> labels = const {},
    ShellBackend? backend,
    bool autoDetachOnDisconnect = true,
    Duration? autoDetachTimeout,
    Duration cleanupInterval = const Duration(minutes: 1),
    Clock? clock,
  }) async {
    final node = NodeRuntime(
      NodeConfig(
        hubUri: hubUri,
        nodeId: NodeId(id),
        labels: labels,
        credentials: TokenCredentialProvider(
          principal: principal,
          token: token,
        ),
        backend: backend ?? ProcessShellBackend(),
        securityContext: trustContext(),
        onBadCertificate: (cert, host, port) => true,
        heartbeatInterval: const Duration(milliseconds: 200),
        pingInterval: const Duration(milliseconds: 300),
        autoDetachOnDisconnect: autoDetachOnDisconnect,
        autoDetachTimeout: autoDetachTimeout,
        cleanupInterval: cleanupInterval,
        clock: clock ?? const SystemClock(),
      ),
    );
    _nodes.add(node);
    await node.connect();
    return node;
  }

  /// Connects an authenticated client to the hub.
  Future<ClientRuntime> connectClient({
    String token = 'admin-token',
    String principal = 'alice',
  }) async {
    final client = ClientRuntime(
      ClientConfig(
        hubUri: hubUri,
        credentials: TokenCredentialProvider(
          principal: principal,
          token: token,
        ),
        securityContext: trustContext(),
        onBadCertificate: (cert, host, port) => true,
      ),
    );
    _clients.add(client);
    await client.connect();
    return client;
  }

  /// Tears down all clients, nodes and the hub.
  Future<void> dispose() async {
    for (final client in _clients) {
      await client.close();
    }
    for (final node in _nodes) {
      await node.shutdown();
    }
    await hub.stop();
  }
}
