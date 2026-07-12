@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

import '../support/fake_shell_backend.dart';
import '../support/harness.dart';

/// Resolves a committed test certificate file.
String _certPath(String name) {
  for (final base in ['test/support/certs', 'support/certs']) {
    final f = File('$base/$name');
    if (f.existsSync()) return f.path;
  }
  throw StateError('missing test certificate: $name');
}

void main() {
  late Directory dir;

  /// Writes `fullchain.pem` + `privkey.pem` into [dir] from the test cert,
  /// optionally prepending [chainPrefix] bytes to fullchain.pem to simulate a
  /// renewal (a leading PEM comment changes the file while keeping it valid).
  void writeCerts({List<int> chainPrefix = const []}) {
    final chain = File(_certPath('localhost.crt')).readAsBytesSync();
    final key = File(_certPath('localhost.key')).readAsBytesSync();
    File(
      '${dir.path}/fullchain.pem',
    ).writeAsBytesSync([...chainPrefix, ...chain]);
    File('${dir.path}/privkey.pem').writeAsBytesSync(key);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hub-tls-dir-');
    writeCerts();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 50));

  Future<void> roundTrip(FakeShellBackend backend, ClientRuntime client) async {
    final session = await client.openSession(
      nodeId: 'web-01',
      mode: SessionMode.exec,
      command: 'run',
    );
    final out = StringBuffer();
    session.stdout.listen((d) => out.write(utf8.decode(d)));
    final fake = backend.sessions.last;
    fake.emitStdout('hello-over-tls');
    await fake.complete(0);
    expect(await session.exitCode, 0);
    await pump();
    expect(out.toString(), contains('hello-over-tls'));
  }

  test('serves wss using a certificate directory', () async {
    final cluster = await TestCluster.start(tlsDirectory: dir.path);
    addTearDown(cluster.dispose);
    final backend = FakeShellBackend();
    await cluster.startNode(
      id: 'web-01',
      labels: {'allow-roles': 'admin'},
      backend: backend,
    );
    final client = await cluster.connectClient();
    await roundTrip(backend, client);
  });

  test('rebinds the listener after a certificate renewal', () async {
    final logs = <String>[];
    final cluster = await TestCluster.start(
      tlsDirectory: dir.path,
      tlsReloadInterval: const Duration(milliseconds: 100),
      logger: logs.add,
    );
    addTearDown(cluster.dispose);
    final backend = FakeShellBackend();
    await cluster.startNode(
      id: 'web-01',
      labels: {'allow-roles': 'admin'},
      backend: backend,
    );

    final client1 = await cluster.connectClient();
    await roundTrip(backend, client1);

    // Simulate a renewal writing fresh bytes into fullchain.pem.
    writeCerts(chainPrefix: '# renewed\n'.codeUnits);

    // The periodic reloader should pick up the change and rebind the listener.
    // The rebind is omnyhub's (gap-free: the old listener drains while new
    // connections land on the fresh certificate), so the message is its
    // "TLS certificate renewed" — reaching this logger through the Hub's bridge.
    bool renewed() => logs.any((l) => l.contains('renewed'));
    for (var i = 0; i < 100 && !renewed(); i++) {
      await pump();
    }
    expect(
      renewed(),
      isTrue,
      reason: 'listener should rebind after renewal; logs: $logs',
    );

    // A fresh client connects to the renewed listener and round-trips.
    final client2 = await cluster.connectClient();
    await roundTrip(backend, client2);
  });
}
