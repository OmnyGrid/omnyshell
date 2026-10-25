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

  test('a Hub older than 1.66.0 is reported without a round trip', () async {
    final connection = LoopbackConnection();
    final client = ClientRuntime(
      ClientConfig(
        hubUri: Uri.parse('wss://old-hub:8443'),
        credentials: const TokenCredentialProvider(
          principal: 'alice',
          token: 't',
        ),
        connectionFactory: (uri, {headers}) async => connection,
      ),
    );
    final connecting = client.connect();
    await Future<void>.delayed(Duration.zero);
    // An old Hub's handshake: no hubVersion in its auth reply.
    connection
      ..deliver(
        const ControlFrame(
          Hello(role: 'hub', protocolVersion: 1, minVersion: 1, nonce: 'n'),
        ),
      )
      ..deliver(
        const ControlFrame(
          AuthOk(
            principal: 'alice',
            displayName: 'Alice',
            roles: [],
            sessionToken: 't',
          ),
        ),
      );
    await connecting;

    expect(client.hubVersion, isNull);
    expect(client.hubInfo, throwsA(isA<HubTooOldException>()));
    expect(
      connection.sent.whereType<ControlFrame>().map((f) => f.message),
      isNot(contains(isA<HubInfoRequest>())),
    );
    await client.close();
  });
}
