@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyhub/omnyhub.dart' as omnyhub;
import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

import '../support/fake_shell_backend.dart';
import '../support/harness.dart';

/// The OmnyShell broker hosted on a listener OmnyShell does **not** own.
///
/// This is what lets another Hub — an OmnyServer Hub, say — serve OmnyShell
/// nodes on its own port, at its own path, beside its own surfaces. The
/// standalone [OmnyShellHub] is just one embedder of the same broker; here we
/// stand up a bare omnyhub hub, mount the broker at `/shell`, and drive a real
/// node and client through it.
void main() {
  late omnyhub.OmnyHub host;
  late HubBroker broker;
  final nodes = <NodeRuntime>[];
  final clients = <ClientRuntime>[];
  late Directory home;

  final grants = {
    'node-token': TokenGrant(
      principal: PrincipalId('node-account'),
      roles: {'node'},
    ),
    'admin-token': TokenGrant(
      principal: PrincipalId('alice'),
      displayName: 'Alice',
      roles: {'admin'},
    ),
  };

  setUp(() async {
    home = Directory.systemTemp.createTempSync('omnyshell-mount-');
    broker = HubBroker(
      authenticator: TokenAuthenticator(grants),
      authorizer: const RoleBasedAuthorizer(),
    );

    host = omnyhub.OmnyHub(
      transports: [
        omnyhub.HttpTransport.https(
          address: '127.0.0.1',
          port: 0,
          tls: omnyhub.StaticTls.context(hubSecurityContext()),
        ),
      ],
    );
    // A path mount, not the root — the host hub keeps the rest of the port.
    await host.registerService(OmnyShellHubService(broker, mount: '/shell'));
    // Another surface on the same listener, to prove they coexist.
    await host.registerService(
      omnyhub.HandlerService(
        name: 'other',
        mount: '/other',
        handler: (_) async => omnyhub.HubResponse.json({'ok': true}),
      ),
    );
    await host.start();
  });

  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    for (final n in nodes) {
      await n.shutdown();
    }
    nodes.clear();
    clients.clear();
    await host.stop();
    home.deleteSync(recursive: true);
  });

  Uri shellUri() => Uri.parse('wss://127.0.0.1:${host.port}/shell');

  Future<NodeRuntime> startNode(String id, ShellBackend backend) async {
    final node = NodeRuntime(
      NodeConfig(
        hubUri: shellUri(),
        nodeId: NodeId(id),
        credentials: const TokenCredentialProvider(
          principal: 'node-account',
          token: 'node-token',
        ),
        backend: backend,
        labels: const {'allow-roles': 'admin'},
        securityContext: trustContext(),
        onBadCertificate: (_, _, _) => true,
        home: home.path,
      ),
    );
    nodes.add(node);
    await node.connect();
    return node;
  }

  Future<ClientRuntime> connectClient() async {
    final client = ClientRuntime(
      ClientConfig(
        hubUri: shellUri(),
        credentials: const TokenCredentialProvider(
          principal: 'alice',
          token: 'admin-token',
        ),
        connectionFactory: ioConnectionFactory(
          securityContext: trustContext(),
          onBadCertificate: (_, _, _) => true,
        ),
      ),
    );
    clients.add(client);
    await client.connect();
    return client;
  }

  test('a node registers with a broker mounted on a foreign hub', () async {
    await startNode('web-01', FakeShellBackend());

    expect(broker.registry.all, hasLength(1));
    expect(broker.registry.byId(NodeId('web-01'))?.descriptor.online, isTrue);
  });

  test('a client opens a session and runs a command end to end', () async {
    final backend = FakeShellBackend();
    await startNode('web-01', backend);
    final client = await connectClient();

    final session = await client.openSession(
      nodeId: 'web-01',
      mode: SessionMode.exec,
      command: 'run',
    );
    final out = StringBuffer();
    session.stdout.listen((d) => out.write(utf8.decode(d)));

    final fake = backend.sessions.last;
    fake.emitStdout('hello-from-a-foreign-hub');
    await fake.complete(0);

    expect(await session.exitCode, 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(out.toString(), contains('hello-from-a-foreign-hub'));
  });

  test('the host hub keeps its own surfaces on the same port', () async {
    await startNode('web-01', FakeShellBackend());

    final client = HttpClient(context: trustContext())
      ..badCertificateCallback = (_, _, _) => true;
    final req = await client.getUrl(
      Uri.parse('https://127.0.0.1:${host.port}/other'),
    );
    final res = await req.close();
    final body = jsonDecode(await res.transform(utf8.decoder).join());
    client.close();

    // Shell traffic on /shell, the host's own service on /other, one listener.
    expect(res.statusCode, 200);
    expect((body as Map)['ok'], isTrue);
    expect(broker.registry.all, hasLength(1));
  });

  test(
    'a plain GET on the shell mount reports status, not an upgrade',
    () async {
      final client = HttpClient(context: trustContext())
        ..badCertificateCallback = (_, _, _) => true;
      final req = await client.getUrl(
        Uri.parse('https://127.0.0.1:${host.port}/shell'),
      );
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join());
      client.close();

      expect(res.statusCode, 200);
      expect((body as Map)['service'], 'omnyshell');
    },
  );

  test('NodeConfig.home isolates the persisted node UID', () async {
    // Two runtimes in one process would otherwise contend on the single
    // ~/.omnyshell/node.uid — the case an embedded shell node creates.
    await startNode('web-01', FakeShellBackend());

    expect(
      File('${home.path}/.omnyshell/node.uid').existsSync(),
      isTrue,
      reason: 'the UID must be persisted under the configured home',
    );
  });
}
