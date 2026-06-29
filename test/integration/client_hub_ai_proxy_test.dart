@TestOn('vm')
library;

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

void main() {
  late TestCluster cluster;
  tearDown(() async => cluster.dispose());

  test('client fetches the hub default AI config (without the key)', () async {
    cluster = await TestCluster.start(
      aiConfig: const AiConfig(
        provider: AiProviderKind.anthropic,
        model: 'claude-haiku-4-5',
        apiKey: 'sk-secret',
        plannerModel: 'claude-sonnet-4-6',
      ),
    );
    final client = await cluster.connectClient(
      token: 'dev-token',
      principal: 'dev',
    );

    final config = await client.fetchHubAiConfig();
    expect(config.available, isTrue);
    expect(config.provider, 'anthropic');
    expect(config.model, 'claude-haiku-4-5');
    expect(config.plannerModel, 'claude-sonnet-4-6');
  });

  test('reports unavailable when the hub has no AI config', () async {
    cluster = await TestCluster.start();
    final client = await cluster.connectClient(
      token: 'dev-token',
      principal: 'dev',
    );

    final config = await client.fetchHubAiConfig();
    expect(config.available, isFalse);
    expect(config.provider, isNull);
  });

  test('proxy rejects a non-allowlisted host (no network)', () async {
    cluster = await TestCluster.start();
    final client = await cluster.connectClient(
      token: 'dev-token',
      principal: 'dev',
    );

    final res = await client.proxyHttp(
      method: 'POST',
      url: 'https://evil.test/v1',
      body: '{}',
    );
    expect(res.statusCode, 0);
    expect(res.error, contains('host not allowed'));
  });
}
