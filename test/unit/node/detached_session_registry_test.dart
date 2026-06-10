import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/src/application/node/detached_session_registry.dart';
import 'package:test/test.dart';

import '../../support/fake_shell_backend.dart';

DetachedNodeSession _session({
  required String id,
  required String owner,
  DateTime? expiresAt,
  FakeShellSession? shell,
}) {
  final fake = shell ?? FakeShellSession();
  return DetachedNodeSession(
    sessionId: id,
    shortId: shortId(id),
    ownerPrincipal: owner,
    nodeId: NodeId('node-1'),
    mode: SessionMode.shell,
    createdAt: DateTime.utc(2026, 1, 1),
    detachedAt: DateTime.utc(2026, 1, 1),
    expiresAt: expiresAt,
    pump: ShellOutputPump(fake),
  );
}

void main() {
  group('DetachedSessionRegistry', () {
    test('lists only the owner\'s sessions', () {
      final reg = DetachedSessionRegistry();
      reg.add(_session(id: 'aaaa1111-0000', owner: 'alice'));
      reg.add(_session(id: 'bbbb2222-0000', owner: 'alice'));
      reg.add(_session(id: 'cccc3333-0000', owner: 'bob'));

      expect(reg.listForOwner('alice').length, 2);
      expect(reg.listForOwner('bob').length, 1);
      expect(reg.listForOwner('carol'), isEmpty);
    });

    test('resolveRef matches a short-id prefix scoped to the owner', () {
      final reg = DetachedSessionRegistry();
      reg.add(_session(id: 'abcd1234-ffff', owner: 'alice'));

      final byShort = reg.resolveRef('alice', shortId('abcd1234-ffff'));
      expect(byShort.status, SessionRefStatus.found);

      final byPrefix = reg.resolveRef('alice', 'abcd');
      expect(byPrefix.status, SessionRefStatus.found);

      final byFull = reg.resolveRef('alice', 'abcd1234-ffff');
      expect(byFull.status, SessionRefStatus.found);
    });

    test('resolveRef never reveals another owner\'s session', () {
      final reg = DetachedSessionRegistry();
      reg.add(_session(id: 'abcd1234-ffff', owner: 'alice'));

      final asBob = reg.resolveRef('bob', 'abcd');
      expect(asBob.status, SessionRefStatus.notFound);
    });

    test('resolveRef reports ambiguous prefixes', () {
      final reg = DetachedSessionRegistry();
      reg.add(_session(id: 'aaaa0000-1111', owner: 'alice'));
      reg.add(_session(id: 'aaaa0000-2222', owner: 'alice'));

      final res = reg.resolveRef('alice', 'aaaa');
      expect(res.status, SessionRefStatus.ambiguous);
      expect(res.session, isNull);
    });

    test('killExpired terminates only past-due sessions', () async {
      final reg = DetachedSessionRegistry();
      final live = FakeShellSession();
      final dead = FakeShellSession();
      reg.add(
        _session(
          id: 'live-0000',
          owner: 'alice',
          shell: live,
          expiresAt: DateTime.utc(2026, 1, 2),
        ),
      );
      reg.add(
        _session(
          id: 'dead-0000',
          owner: 'alice',
          shell: dead,
          expiresAt: DateTime.utc(2026, 1, 1, 0, 0, 30),
        ),
      );

      final removed = await reg.killExpired(DateTime.utc(2026, 1, 1, 1));
      expect(removed, 1);
      expect(dead.killed, isTrue);
      expect(live.killed, isFalse);
      expect(reg.length, 1);
    });

    test(
      'a session that exits on its own is dropped from the registry',
      () async {
        final reg = DetachedSessionRegistry();
        final shell = FakeShellSession();
        reg.add(_session(id: 'exit-0000', owner: 'alice', shell: shell));
        expect(reg.length, 1);

        await shell.complete(0);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(reg.length, 0);
      },
    );
  });
}
