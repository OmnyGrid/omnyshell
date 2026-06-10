import 'dart:async';
import 'dart:convert';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:test/test.dart';

import '../support/fake_shell_backend.dart';
import '../support/harness.dart';

/// Two admin principals (so node-level ownership — not Hub authorization — is
/// what blocks cross-user access) plus a node account.
Map<String, TokenGrant> _tokens() => {
  'node-token': TokenGrant(
    principal: PrincipalId('node-account'),
    roles: {'node'},
  ),
  'alice-token': TokenGrant(
    principal: PrincipalId('alice'),
    displayName: 'Alice',
    roles: {'admin'},
  ),
  'bob-token': TokenGrant(
    principal: PrincipalId('bob'),
    displayName: 'Bob',
    roles: {'admin'},
  ),
};

Future<void> _settle([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late TestCluster cluster;

  tearDown(() async => cluster.dispose());

  Future<ClientRuntime> alice() =>
      cluster.connectClient(token: 'alice-token', principal: 'alice');

  test(
    'detach keeps the shell alive, resumes, and replays buffered output',
    () async {
      final backend = FakeShellBackend();
      cluster = await TestCluster.start(tokens: _tokens());
      final node = await cluster.startNode(id: 'n1', backend: backend);
      final client = await alice();

      final session = await client.openSession(
        nodeId: 'n1',
        mode: SessionMode.shell,
      );
      await _settle();
      final shell = backend.sessions.single;

      final outcome = await session.detach();
      expect(outcome.shortId, isNotEmpty);
      expect(node.detachedSessions, 1);
      expect(shell.killed, isFalse, reason: 'detach must not kill the shell');

      // Output produced while detached must be preserved (ring buffer).
      shell.emitStdout('while-away\n');
      await _settle();

      final resumed = await client.resumeSession(
        nodeId: 'n1',
        sessionId: outcome.shortId,
      );
      final got = StringBuffer();
      resumed.stdout.listen(
        (b) => got.write(utf8.decode(b, allowMalformed: true)),
      );
      await _settle();

      expect(got.toString(), contains('while-away'));
      expect(
        node.detachedSessions,
        0,
        reason: 'resume removes it from registry',
      );
      expect(shell.killed, isFalse);

      // The resumed session is live: further output flows to the new channel.
      shell.emitStdout('after-resume\n');
      await _settle();
      expect(got.toString(), contains('after-resume'));
    },
  );

  test('another user cannot list, resume or kill the session', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);

    final aliceClient = await alice();
    final session = await aliceClient.openSession(
      nodeId: 'n1',
      mode: SessionMode.shell,
    );
    await _settle();
    final outcome = await session.detach();

    final bob = await cluster.connectClient(
      token: 'bob-token',
      principal: 'bob',
    );

    // Invisible to Bob.
    expect(await bob.listDetachedSessions(nodeId: 'n1'), isEmpty);

    // Bob cannot resume it.
    await expectLater(
      bob.resumeSession(nodeId: 'n1', sessionId: outcome.shortId),
      throwsA(isA<SessionRejectedException>()),
    );

    // Bob cannot kill it.
    final kill = await bob.killDetachedSession(
      nodeId: 'n1',
      sessionRef: outcome.shortId,
    );
    expect(kill.ok, isFalse);

    // Alice still sees exactly her one session, untouched.
    final mine = await aliceClient.listDetachedSessions(nodeId: 'n1');
    expect(mine, hasLength(1));
    expect(mine.single.shortId, outcome.shortId);
    expect(mine.single.ownerUserId, 'alice');
    expect(node.detachedSessions, 1);
    expect(backend.sessions.single.killed, isFalse);
  });

  test('kill terminates the shell and removes it from the registry', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);
    final client = await alice();

    final session = await client.openSession(
      nodeId: 'n1',
      mode: SessionMode.shell,
    );
    await _settle();
    final outcome = await session.detach();

    final res = await client.killDetachedSession(
      nodeId: 'n1',
      sessionRef: outcome.shortId,
    );
    expect(res.ok, isTrue);
    await _settle();
    expect(node.detachedSessions, 0);
    expect(backend.sessions.single.killed, isTrue);
    expect(await client.listDetachedSessions(nodeId: 'n1'), isEmpty);
  });

  test('an abrupt client disconnect auto-detaches the session', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);

    final client = await alice();
    await client.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();

    // Drop the whole connection (simulating a crash / network loss).
    await client.close();
    await _settle(250);

    expect(node.detachedSessions, 1, reason: 'auto-detach preserves the shell');
    expect(backend.sessions.single.killed, isFalse);

    // A fresh connection can list and resume it.
    final again = await alice();
    final list = await again.listDetachedSessions(nodeId: 'n1');
    expect(list, hasLength(1));
    final resumed = await again.resumeSession(
      nodeId: 'n1',
      sessionId: list.single.shortId,
    );
    expect(resumed.id, isNotNull);
  });

  test('a deliberate exit terminates the session', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);
    final client = await alice();

    final session = await client.openSession(
      nodeId: 'n1',
      mode: SessionMode.shell,
    );
    await _settle();
    await session.close();
    await _settle();

    expect(node.detachedSessions, 0, reason: 'close() must not park the shell');
    expect(backend.sessions.single.killed, isTrue);
  });

  test('expired detached sessions are cleaned up', () async {
    final clock = FixedClock();
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(
      id: 'n1',
      backend: backend,
      clock: clock,
      cleanupInterval: const Duration(milliseconds: 80),
    );
    final client = await alice();

    final session = await client.openSession(
      nodeId: 'n1',
      mode: SessionMode.shell,
    );
    await _settle();
    final outcome = await session.detach(timeout: const Duration(seconds: 10));
    expect(outcome.expiresAt, isNotNull);
    expect(node.detachedSessions, 1);

    // Move past the expiry; the periodic cleaner should reap it.
    clock.advance(const Duration(seconds: 11));
    await _settle(250);

    expect(node.detachedSessions, 0);
    expect(backend.sessions.single.killed, isTrue);
  });

  test('multiple sessions are listed and prefix-resolved per owner', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);
    final client = await alice();

    final s1 = await client.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();
    final o1 = await s1.detach();
    final s2 = await client.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();
    final o2 = await s2.detach();

    expect(node.detachedSessions, 2);
    final list = await client.listDetachedSessions(nodeId: 'n1');
    expect(list.map((s) => s.shortId), containsAll([o1.shortId, o2.shortId]));

    // Resume the second by its short id; the first remains detached. The
    // resumed session reports the *original* session id (so the prompt-marker
    // token is stable across connect/resume), and the detached short id stays
    // stable in the node registry, which is what resume/kill use.
    final resumed = await client.resumeSession(
      nodeId: 'n1',
      sessionId: o2.shortId,
    );
    expect(resumed.id!.value, o2.sessionId);
    expect(node.detachedSessions, 1);
    final remaining = await client.listDetachedSessions(nodeId: 'n1');
    expect(remaining.single.shortId, o1.shortId);
  });

  test(
    'an active session can be detached from another window (no id)',
    () async {
      final backend = FakeShellBackend();
      cluster = await TestCluster.start(tokens: _tokens());
      final node = await cluster.startNode(id: 'n1', backend: backend);

      final a = await alice();
      final session = await a.openSession(
        nodeId: 'n1',
        mode: SessionMode.shell,
      );
      await _settle();
      final shell = backend.sessions.single;

      // A second connection (another window), same user, detaches it.
      final b = await alice();
      final res = await b.detachActiveSession(nodeId: 'n1');
      expect(res.ok, isTrue);
      expect(res.shortId, isNotEmpty);

      await _settle();
      // The attached session A is notified and ends, but the shell lives on.
      expect(session.wasDetached, isTrue);
      expect(await session.exitCode, 0);
      expect(node.activeSessions, 0);
      expect(node.detachedSessions, 1);
      expect(shell.killed, isFalse);

      // Still resumable.
      final resumed = await b.resumeSession(
        nodeId: 'n1',
        sessionId: res.shortId,
      );
      expect(resumed.id, isNotNull);
    },
  );

  test('a specific active session is detached by short id', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);

    final a = await alice();
    final s1 = await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();
    final s2 = await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();
    expect(node.activeSessions, 2);

    final b = await alice();
    // No id with several active is ambiguous.
    final ambiguous = await b.detachActiveSession(nodeId: 'n1');
    expect(ambiguous.ok, isFalse);

    // Detach s2 specifically by its short id (read from the listing).
    final list = await b.listSessions(nodeId: 'n1');
    expect(list.where((s) => s.state == SessionState.attached).length, 2);
    final s2Info = list.firstWhere((s) => s.sessionId == s2.id!.value);
    final res = await b.detachActiveSession(
      nodeId: 'n1',
      sessionRef: s2Info.shortId,
    );
    expect(res.ok, isTrue);

    await _settle();
    expect(s2.wasDetached, isTrue);
    expect(s1.wasDetached, isFalse);
    expect(node.activeSessions, 1);
    expect(node.detachedSessions, 1);
  });

  test(
    'resuming a full-screen program replays its frame and flags alt-screen',
    () async {
      final backend = FakeShellBackend();
      cluster = await TestCluster.start(tokens: _tokens());
      final node = await cluster.startNode(id: 'n1', backend: backend);
      final a = await alice();

      final session = await a.openSession(
        nodeId: 'n1',
        mode: SessionMode.shell,
      );
      await _settle();
      final shell = backend.sessions.single;

      // While attached, the program enters the alternate screen and draws — this
      // is the state we must restore even though no output follows the detach.
      shell.emitStdout('\x1b[?1049hNANO-EDITOR-FRAME');
      await _settle();

      final outcome = await session.detach();
      expect(node.detachedSessions, 1);

      final resumed = await a.resumeSession(
        nodeId: 'n1',
        sessionId: outcome.shortId,
      );
      expect(resumed.resumedInAltScreen, isTrue);

      final got = StringBuffer();
      resumed.stdout.listen(
        (b) => got.write(utf8.decode(b, allowMalformed: true)),
      );
      await _settle();
      // Re-enters the alt screen and repaints the frame drawn before detaching.
      expect(got.toString(), contains('\x1b[?1049h'));
      expect(got.toString(), contains('NANO-EDITOR-FRAME'));
    },
  );

  test('resuming after the program exited does not flag alt-screen', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    await cluster.startNode(id: 'n1', backend: backend);
    final a = await alice();

    final session = await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();
    final shell = backend.sessions.single;
    // Enter then leave the alt screen (program opened and closed).
    shell.emitStdout('\x1b[?1049hin-editor\x1b[?1049l\r\nback-to-shell');
    await _settle();

    final outcome = await session.detach();
    final resumed = await a.resumeSession(
      nodeId: 'n1',
      sessionId: outcome.shortId,
    );
    expect(resumed.resumedInAltScreen, isFalse);
  });

  test('a running (attached) session can be killed', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);

    final a = await alice();
    final session = await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();
    final shell = backend.sessions.single;

    // Kill it from another window by its short id.
    final b = await alice();
    final list = await b.listSessions(nodeId: 'n1');
    final info = list.firstWhere((s) => s.sessionId == session.id!.value);
    final res = await b.killSession(nodeId: 'n1', sessionRef: info.shortId);
    expect(res.ok, isTrue);

    await _settle();
    // The shell is terminated, the attached client is notified, and nothing is
    // parked.
    expect(shell.killed, isTrue);
    expect(await session.exitCode, isNot(0));
    expect(session.wasDetached, isFalse);
    expect(node.activeSessions, 0);
    expect(node.detachedSessions, 0);
  });

  test('another user cannot kill your running session', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);

    final a = await alice();
    final session = await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();

    final bob = await cluster.connectClient(
      token: 'bob-token',
      principal: 'bob',
    );
    final res = await bob.killSession(
      nodeId: 'n1',
      sessionRef: session.id!.value,
    );
    expect(res.ok, isFalse);
    expect(node.activeSessions, 1);
    expect(backend.sessions.single.killed, isFalse);
  });

  test('another user cannot detach your active session', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);

    final a = await alice();
    await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();

    final bob = await cluster.connectClient(
      token: 'bob-token',
      principal: 'bob',
    );
    final res = await bob.detachActiveSession(nodeId: 'n1');
    expect(res.ok, isFalse);
    expect(await bob.listSessions(nodeId: 'n1'), isEmpty);
    expect(node.activeSessions, 1);
    expect(backend.sessions.single.killed, isFalse);
  });

  test('peek shows a detached session screen without disturbing it', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    final node = await cluster.startNode(id: 'n1', backend: backend);
    final client = await alice();

    final session = await client.openSession(
      nodeId: 'n1',
      mode: SessionMode.shell,
    );
    await _settle();
    final shell = backend.sessions.single;
    shell.emitStdout('hello-screen\n');
    await _settle();
    final outcome = await session.detach();
    expect(node.detachedSessions, 1);

    final peek = await client.peekSession(
      nodeId: 'n1',
      sessionRef: outcome.shortId,
    );
    expect(peek.ok, isTrue);
    expect(peek.altScreen, isFalse);
    expect(
      utf8.decode(peek.screen, allowMalformed: true),
      contains('hello-screen'),
    );

    // Peeking is read-only: the session stays parked and remains resumable.
    expect(node.detachedSessions, 1);
    expect(shell.killed, isFalse);
    final resumed = await client.resumeSession(
      nodeId: 'n1',
      sessionId: outcome.shortId,
    );
    expect(resumed.id, isNotNull);
  });

  test('peek captures a running session and flags alt-screen', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    await cluster.startNode(id: 'n1', backend: backend);

    final a = await alice();
    final session = await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();
    final shell = backend.sessions.single;
    shell.emitStdout('\x1b[?1049hFULLSCREEN-FRAME');
    await _settle();

    // A second window peeks the still-attached session by its short id.
    final b = await alice();
    final list = await b.listSessions(nodeId: 'n1');
    final info = list.firstWhere((s) => s.sessionId == session.id!.value);
    final peek = await b.peekSession(nodeId: 'n1', sessionRef: info.shortId);
    expect(peek.ok, isTrue);
    expect(peek.altScreen, isTrue);
    expect(
      utf8.decode(peek.screen, allowMalformed: true),
      contains('FULLSCREEN-FRAME'),
    );
  });

  test('peek rejects unknown refs and other users', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    await cluster.startNode(id: 'n1', backend: backend);

    final a = await alice();
    final session = await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();
    final outcome = await session.detach();

    final unknown = await a.peekSession(nodeId: 'n1', sessionRef: 'zzzzzz');
    expect(unknown.ok, isFalse);
    expect(unknown.screen, isEmpty);

    // Another user cannot peek it (not found — existence is never revealed).
    final bob = await cluster.connectClient(
      token: 'bob-token',
      principal: 'bob',
    );
    final denied = await bob.peekSession(
      nodeId: 'n1',
      sessionRef: outcome.shortId,
    );
    expect(denied.ok, isFalse);
  });

  test('listSessions shows attached; listDetachedSessions does not', () async {
    final backend = FakeShellBackend();
    cluster = await TestCluster.start(tokens: _tokens());
    await cluster.startNode(id: 'n1', backend: backend);

    final a = await alice();
    await a.openSession(nodeId: 'n1', mode: SessionMode.shell);
    await _settle();

    final all = await a.listSessions(nodeId: 'n1');
    expect(all, hasLength(1));
    expect(all.single.state, SessionState.attached);
    expect(all.single.detachedAt, isNull);
    expect(await a.listDetachedSessions(nodeId: 'n1'), isEmpty);
  });
}
