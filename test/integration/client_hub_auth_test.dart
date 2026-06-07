@TestOn('vm')
library;

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

void main() {
  late TestCluster cluster;

  setUp(() async => cluster = await TestCluster.start());
  tearDown(() async => cluster.dispose());

  test('a valid token authenticates and resolves the principal', () async {
    final client = await cluster.connectClient();
    expect(client.isConnected, isTrue);
    expect(client.principal!.id.value, 'alice');
    expect(client.principal!.hasRole('admin'), isTrue);
  });

  test('an invalid token is rejected with an AuthException', () async {
    final client = ClientRuntime(
      ClientConfig(
        hubUri: cluster.hubUri,
        credentials: const TokenCredentialProvider(
          principal: 'alice',
          token: 'wrong-token',
        ),
        securityContext: trustContext(),
        onBadCertificate: (cert, host, port) => true,
      ),
    );
    await expectLater(client.connect(), throwsA(isA<AuthException>()));
  });

  test('whoami reflects roles from the grant', () async {
    final client = await cluster.connectClient(
      token: 'dev-token',
      principal: 'dev',
    );
    expect(client.principal!.roles, contains('developer'));
  });

  test('ping measures a non-negative round trip', () async {
    final client = await cluster.connectClient();
    final rtt = await client.ping();
    expect(rtt.inMicroseconds, greaterThanOrEqualTo(0));
  });
}
