@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';
import '../support/loopback_connection.dart';

void main() {
  group('against a live Hub', () {
    late TestCluster cluster;

    setUp(
      () async => cluster = await TestCluster.start(
        tunnelPortRange: const PortRange(20400, 20410),
      ),
    );
    tearDown(() async => cluster.dispose());

    test('login reports the Hub version', () async {
      final client = await cluster.connectClient();
      expect(client.hubVersion, omnyShellVersion);
    });

    test('hubInfo describes the Hub, its machine and activity', () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      await cluster.connectClient(token: 'dev-token', principal: 'dev');

      final info = await client.hubInfo();
      expect(info.version, omnyShellVersion);
      expect(info.protocolVersion, kProtocolVersion);
      expect(info.minProtocolVersion, kMinProtocolVersion);
      expect(info.platform.os, Platform.operatingSystem);
      expect(info.platform.agentVersion, omnyShellVersion);
      expect(info.platform.hostname, Platform.localHostname);
      expect(info.platform.cpuCount, Platform.numberOfProcessors);
      expect(info.platform.runtimeVersion, isNotNull);
      expect(info.uptime.isNegative, isFalse);
      expect(info.nodes, 1);
      expect(info.onlineNodes, 1);
      expect(info.clients, 2);
      expect(info.sessions, 0);
      expect(info.tunnels, 0);
      expect(info.tunnelPorts, '20400-20410');
      expect(info.aiProvider, isNull);
    });

    test('counts open sessions, and only the caller\'s tunnels', () async {
      await cluster.startNode(id: 'web-01');
      final alice = await cluster.connectClient();
      final dev = await cluster.connectClient(
        token: 'dev-token',
        principal: 'dev',
      );
      final session = await alice.openSession(
        nodeId: 'web-01',
        mode: SessionMode.shell,
      );
      addTearDown(session.close);
      await alice.openTunnel(nodeId: 'web-01', targetPort: 9);

      final mine = await alice.hubInfo();
      expect(mine.sessions, 1);
      expect(mine.tunnels, 1);
      // Another principal sees the shared counts but none of alice's tunnels.
      final theirs = await dev.hubInfo();
      expect(theirs.sessions, 1);
      expect(theirs.tunnels, 0);
    });
  });

  test('a Hub with a default AI provider names it, never its key', () async {
    final cluster = await TestCluster.start(
      aiConfig: const AiConfig(
        provider: AiProviderKind.anthropic,
        model: 'claude-haiku-4-5',
        apiKey: 'sk-secret',
      ),
    );
    addTearDown(cluster.dispose);
    final client = await cluster.connectClient();

    final info = await client.hubInfo();
    expect(info.aiProvider, 'anthropic');
    expect(info.tunnelPorts, isNull); // tunneling disabled on this Hub
    expect(info.toJson().toString(), isNot(contains('sk-secret')));
  });

  /// A client logged in over [connection] to a scripted Hub whose auth reply
  /// carries [hubVersion] (`null` plays a Hub older than 1.66.0).
  Future<ClientRuntime> scriptedLogin(
    LoopbackConnection connection, {
    String? hubVersion,
  }) async {
    final client = ClientRuntime(
      ClientConfig(
        hubUri: Uri.parse('wss://scripted-hub:8443'),
        credentials: const TokenCredentialProvider(
          principal: 'alice',
          token: 't',
        ),
        connectionFactory: (uri, {headers}) async => connection,
      ),
    );
    final connecting = client.connect();
    await Future<void>.delayed(Duration.zero);
    connection
      ..deliver(
        const ControlFrame(
          Hello(role: 'hub', protocolVersion: 1, minVersion: 1, nonce: 'n'),
        ),
      )
      ..deliver(
        ControlFrame(
          AuthOk(
            principal: 'alice',
            displayName: 'Alice',
            roles: const [],
            sessionToken: 't',
            hubVersion: hubVersion,
          ),
        ),
      );
    await connecting;
    return client;
  }

  test('a dropped connection fails a pending hubInfo', () async {
    final connection = LoopbackConnection();
    final client = await scriptedLogin(connection, hubVersion: '1.66.0');
    expect(client.hubVersion, '1.66.0');

    final pending = client.hubInfo();
    await Future<void>.delayed(Duration.zero);
    expect(
      connection.sent.whereType<ControlFrame>().map((f) => f.message),
      contains(isA<HubInfoRequest>()),
    );
    await connection.close();

    await expectLater(pending, throwsA(isA<TransportException>()));
    expect(client.hubVersion, isNull);
  });

  test('a Hub older than 1.66.0 is reported without a round trip', () async {
    final connection = LoopbackConnection();
    // An old Hub's handshake: no hubVersion in its auth reply.
    final client = await scriptedLogin(connection);

    expect(client.hubVersion, isNull);
    // A failed future, not a synchronous throw, so Future-style callers
    // (`.catchError`) see it.
    final result = client.hubInfo();
    await expectLater(result, throwsA(isA<HubTooOldException>()));
    expect(
      connection.sent.whereType<ControlFrame>().map((f) => f.message),
      isNot(contains(isA<HubInfoRequest>())),
    );
    await client.close();
  });
}
