@TestOn('vm')
library;

import 'dart:convert';

import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

import '../support/fake_shell_backend.dart';
import '../support/harness.dart';

void main() {
  late TestCluster cluster;
  late FakeShellBackend backend;

  setUp(() async {
    cluster = await TestCluster.start();
    backend = FakeShellBackend();
  });
  tearDown(() async => cluster.dispose());

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 50));

  test(
    'relays stdout from node to client and propagates the exit code',
    () async {
      await cluster.startNode(
        id: 'web-01',
        labels: {'allow-roles': 'developer'},
        backend: backend,
      );
      final client = await cluster.connectClient(
        token: 'dev-token',
        principal: 'dev',
      );

      final session = await client.openSession(
        nodeId: 'web-01',
        mode: SessionMode.exec,
        command: 'run',
      );
      final out = StringBuffer();
      session.stdout.listen((d) => out.write(utf8.decode(d)));

      final fake = backend.sessions.single;
      fake.emitStdout('hello-from-node');
      await fake.complete(7);

      expect(await session.exitCode, 7);
      await pump();
      expect(out.toString(), contains('hello-from-node'));
      expect(backend.lastRequest!.command, 'run');
    },
  );

  test(
    'keeps streaming stdout past the send window when the client grants credit',
    () async {
      await cluster.startNode(
        id: 'web-01',
        labels: {'allow-roles': 'developer'},
        backend: backend,
      );
      final client = await cluster.connectClient(
        token: 'dev-token',
        principal: 'dev',
      );

      final session = await client.openSession(
        nodeId: 'web-01',
        mode: SessionMode.shell,
      );
      // Mirror the interactive `connect` loop: replenish the node's send window
      // for every chunk consumed. This is the fix under test — without it the
      // node's 256 KiB credit drains and delivery stalls.
      var received = 0;
      session.stdout.listen((d) {
        received += d.length;
        session.grantWindow(d.length);
      });

      // Emit well beyond a single send window in chunks.
      final fake = backend.sessions.single;
      const chunk = 4096;
      final total = Channel.defaultWindow * 4 + chunk; // > 4 windows
      final blob = 'x' * chunk;
      var sent = 0;
      while (sent < total) {
        fake.emitStdout(blob);
        sent += chunk;
        await pump();
      }

      // Wait for the credit round-trips to drain everything.
      for (var i = 0; i < 40 && received < sent; i++) {
        await pump();
      }

      expect(received, sent, reason: 'all stdout should be delivered');
      await session.close();
    },
  );

  test('relays client stdin to the node process', () async {
    await cluster.startNode(
      id: 'web-01',
      labels: {'allow-roles': 'admin'},
      backend: backend,
    );
    final client = await cluster.connectClient();

    final session = await client.openSession(
      nodeId: 'web-01',
      mode: SessionMode.shell,
    );
    session.writeStdin(utf8.encode('echo hi\n'));
    await pump();

    final fake = backend.sessions.single;
    expect(fake.receivedStdinText, 'echo hi\n');
    await session.close();
  });

  test('relays terminal resize and interrupt signals', () async {
    await cluster.startNode(
      id: 'web-01',
      labels: {'allow-roles': 'admin'},
      backend: backend,
    );
    final client = await cluster.connectClient();
    final session = await client.openSession(
      nodeId: 'web-01',
      mode: SessionMode.shell,
    );

    session.resize(cols: 120, rows: 40);
    session.interrupt();
    await pump();

    final fake = backend.sessions.single;
    expect(fake.resizes, contains((120, 40)));
    expect(fake.signals, contains('SIGINT'));
    await session.close();
  });

  test('rejects a session for an unauthorized principal', () async {
    await cluster.startNode(
      id: 'locked',
      labels: {'allow-roles': 'ops'},
      backend: backend,
    );
    final client = await cluster.connectClient(
      token: 'dev-token',
      principal: 'dev',
    );

    await expectLater(
      client.openSession(
        nodeId: 'locked',
        mode: SessionMode.exec,
        command: 'x',
      ),
      throwsA(isA<SessionRejectedException>()),
    );
    expect(backend.sessions, isEmpty);
  });

  test('rejects a session for an unknown node', () async {
    final client = await cluster.connectClient();
    await expectLater(
      client.openSession(nodeId: 'ghost', mode: SessionMode.exec, command: 'x'),
      throwsA(isA<SessionRejectedException>()),
    );
  });

  test('writes an audit trail for authentication and sessions', () async {
    await cluster.startNode(
      id: 'web-01',
      labels: {'allow-roles': 'admin'},
      backend: backend,
    );
    final client = await cluster.connectClient();
    final session = await client.openSession(
      nodeId: 'web-01',
      mode: SessionMode.exec,
      command: 'run',
    );
    await backend.sessions.single.complete(0);
    await session.exitCode;
    await pump();

    final actions = cluster.hub.audit.records.map((r) => r.action).toSet();
    expect(actions, containsAll({'auth.ok', 'node.register', 'session.open'}));
  });
}
