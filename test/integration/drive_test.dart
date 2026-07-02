@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:omnydrive/omnydrive.dart'
    show PathFilter, SyncDirection, SyncStatus;
import 'package:omnyshell/src/application/client/drive/drive_manager.dart';
import 'package:omnyshell/src/application/client/drive/mount_store.dart';
import 'package:omnyshell/src/shared/utils/progress_bar.dart'
    show formatDriveChanges, formatFileDiff;
import 'package:test/test.dart';

import '../support/harness.dart';

void main() {
  late TestCluster cluster;
  late Directory tmp;
  late String home;

  setUp(() async {
    cluster = await TestCluster.start();
    tmp = Directory.systemTemp.createTempSync('omnydrive-it');
    home = '${tmp.path}/home'; // isolates ~/.omnyshell/mounts.json
  });
  tearDown(() async {
    await cluster.dispose();
    tmp.deleteSync(recursive: true);
  });

  Directory localDir() {
    final d = Directory('${tmp.path}/src')..createSync();
    File('${d.path}/a.txt').writeAsStringSync('alpha');
    Directory('${d.path}/sub').createSync();
    File('${d.path}/sub/b.txt').writeAsStringSync('beta');
    return d;
  }

  String remotePath() => '${tmp.path}/remote';

  test('mounts a directory and populates the node path', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);

    final rec = await mgr.mountDirectory(
      localDir: localDir().path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );

    expect(rec.kind, 'dir');
    expect(File('${remotePath()}/a.txt').readAsStringSync(), 'alpha');
    expect(File('${remotePath()}/sub/b.txt').readAsStringSync(), 'beta');
    // The record persisted and reloads.
    final reloaded = await DriveManager.open(client, home: home);
    expect(reloaded.get(rec.id), isNotNull);
  });

  test('pushes local edits on sync', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );

    File('${src.path}/a.txt').writeAsStringSync('ALPHA-2');
    File('${src.path}/c.txt').writeAsStringSync('gamma');
    final out = await mgr.sync(rec.id);

    expect(out.direction, SyncDirection.push);
    expect(File('${remotePath()}/a.txt').readAsStringSync(), 'ALPHA-2');
    expect(File('${remotePath()}/c.txt').readAsStringSync(), 'gamma');
  });

  test('preserves the executable bit when populating the node', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    File('${src.path}/run.sh').writeAsStringSync('#!/bin/sh\necho hi\n');
    Process.runSync('chmod', ['+x', '${src.path}/run.sh']);

    await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );

    // The executable script lands +x on the node; a plain file does not.
    expect(File('${remotePath()}/run.sh').statSync().mode & 0x49, isNonZero);
    expect(File('${remotePath()}/a.txt').statSync().mode & 0x49, isZero);
  }, testOn: '!windows');

  test('pulls node edits back on a read-write mount (auto)', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final rec = await mgr.mountDirectory(
      localDir: localDir().path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // Change the node side out of band; auto-sync should pull it down.
    File('${remotePath()}/a.txt').writeAsStringSync('edited-on-node');
    final out = await mgr.sync(rec.id);

    expect(out.direction, SyncDirection.pull);
    expect(File('${rec.localPath}/a.txt').readAsStringSync(), 'edited-on-node');
  });

  test('pulls a new node file down to local on a read-write mount', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final rec = await mgr.mountDirectory(
      localDir: localDir().path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // A brand new file appears on the node only; local is unchanged. Auto-sync
    // pulls it down to the local origin.
    File('${remotePath()}/added-on-node.txt').writeAsStringSync('from-node');
    final out = await mgr.sync(rec.id);

    expect(out.direction, SyncDirection.pull);
    expect(
      File('${rec.localPath}/added-on-node.txt').readAsStringSync(),
      'from-node',
    );
  });

  test('read-only mount does not copy new node files to local', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    // Read-only: the node is never authoritative, so a sync never pulls its
    // changes into the local origin.
    final rec = await mgr.mountDirectory(
      localDir: localDir().path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );

    // A new file appears on the node only.
    File('${remotePath()}/added-on-node.txt').writeAsStringSync('from-node');
    final out = await mgr.sync(rec.id);

    // It is never copied down to the local origin...
    expect(File('${rec.localPath}/added-on-node.txt').existsSync(), isFalse);
    // ...and the read-only sync does not delete it from the node either: the
    // node drifted off the baseline, so the push conflicts rather than
    // clobbering the remote file.
    expect(out.isConflict, isTrue);
    expect(
      File('${remotePath()}/added-on-node.txt').readAsStringSync(),
      'from-node',
    );
  });

  test('detects a conflict on forced push and resolves accept-local', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // Node drifts off the baseline behind our back.
    File('${remotePath()}/a.txt').writeAsStringSync('node-drift');

    final conflicted = await mgr.sync(rec.id, direction: SyncDirection.push);
    expect(conflicted.isConflict, isTrue);

    // accept-local re-anchors and overwrites the node with the local copy.
    final resolved = await mgr.resolve(rec.id, strategy: 'accept-local');
    expect(resolved.isConflict, isFalse);
    expect(File('${remotePath()}/a.txt').readAsStringSync(), 'alpha');
  });

  // Regression guards for omnydrive >=1.1.2: a sync must never silently discard
  // local-only changes by pulling the origin over them. omnyshell enforces this
  // in DriveManager._autoDirection (read-only always pushes; read-write only
  // pulls when local is unchanged; a two-sided change conflicts).

  test(
    'auto-sync refuses to discard local work when both sides diverged',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );

      // Both sides move off the baseline: local edits a file, the node edits the
      // same file out of band. A blind pull would overwrite the local edit.
      File('${src.path}/a.txt').writeAsStringSync('local-edit');
      File('${remotePath()}/a.txt').writeAsStringSync('node-edit');

      // Auto-direction refuses to guess rather than destroying either side,
      // and the error lists the diverging path so the operator can act on it.
      await expectLater(
        mgr.sync(rec.id),
        throwsA(
          isA<DriveConflictException>().having(
            (e) => e.message,
            'message',
            allOf(contains('diverged path'), contains('a.txt')),
          ),
        ),
      );
      // The local copy is preserved, not clobbered by a pull.
      expect(File('${src.path}/a.txt').readAsStringSync(), 'local-edit');
    },
  );

  test('auto-sync merges non-overlapping changes on both sides', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // Different files change on each side — no overlap, so this is mergeable
    // even though both the local and remote trees moved off the baseline.
    File('${src.path}/a.txt').writeAsStringSync('local-a');
    File('${remotePath()}/sub/b.txt').writeAsStringSync('remote-b');

    final out = await mgr.sync(rec.id);
    expect(out.isConflict, isFalse);
    expect(out.merged, isTrue);
    expect(out.pushedPaths, contains('a.txt'));
    expect(out.pulledPaths, contains('sub/b.txt'));
    // Each one-sided change landed on the other side.
    expect(File('${remotePath()}/a.txt').readAsStringSync(), 'local-a');
    expect(File('${src.path}/sub/b.txt').readAsStringSync(), 'remote-b');

    // Converged: a follow-up auto-sync is a clean no-op.
    final again = await mgr.sync(rec.id);
    expect(again.merged, isFalse);
    expect(again.direction, isNull);
    expect(again.isConflict, isFalse);
  });

  test(
    'a mount created before this change still works and gains a snapshot',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );

      // Simulate a legacy record persisted before baseline snapshots existed.
      final legacy = MountRecord.fromJson(
        rec.toJson()..remove('baselineManifest'),
      );
      expect(legacy.baselineManifest, isNull);
      mgr.store.mounts[rec.id] = legacy;

      // A clean sync is a safe no-op and opportunistically captures the snapshot.
      final noop = await mgr.sync(rec.id);
      expect(noop.isConflict, isFalse);
      expect(mgr.get(rec.id)!.baselineManifest, isNotNull);

      // With the snapshot in place, non-overlapping divergence now auto-merges.
      File('${src.path}/a.txt').writeAsStringSync('local-a');
      File('${remotePath()}/sub/b.txt').writeAsStringSync('remote-b');
      final out = await mgr.sync(rec.id);
      expect(out.merged, isTrue);
    },
  );

  test(
    'a legacy mount diverged on both sides conflicts until re-anchored',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );
      // Legacy record (no snapshot) that is ALREADY diverged on both sides.
      final legacy = MountRecord.fromJson(
        rec.toJson()..remove('baselineManifest'),
      );
      mgr.store.mounts[rec.id] = legacy;
      File('${src.path}/a.txt').writeAsStringSync('local-a');
      File('${remotePath()}/sub/b.txt').writeAsStringSync('remote-b');

      // Without a baseline snapshot it cannot tell one-sided edits apart, so it
      // safely falls back to flagging the differences rather than guessing.
      await expectLater(
        mgr.sync(rec.id),
        throwsA(isA<DriveConflictException>()),
      );
      // Resolving re-anchors and records a snapshot; syncs work normally after.
      await mgr.resolve(rec.id, strategy: 'accept-local');
      expect(mgr.get(rec.id)!.baselineManifest, isNotNull);
    },
  );

  test('auto-sync merges a local-only delete with a remote-only edit', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    File('${src.path}/a.txt').deleteSync(); // local removes a.txt
    File(
      '${remotePath()}/sub/b.txt',
    ).writeAsStringSync('remote-b'); // remote edit

    final out = await mgr.sync(rec.id);
    expect(out.merged, isTrue);
    // The local delete propagated to the node; the remote edit propagated local.
    expect(File('${remotePath()}/a.txt').existsSync(), isFalse);
    expect(File('${src.path}/sub/b.txt').readAsStringSync(), 'remote-b');
  });

  test('a divergence lists only the file changed on both sides', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // a.txt is a true two-sided conflict; c.txt is a local-only addition that
    // could be pushed cleanly and must NOT be reported as conflicting.
    File('${src.path}/a.txt').writeAsStringSync('local-a');
    File('${remotePath()}/a.txt').writeAsStringSync('remote-a');
    File('${src.path}/c.txt').writeAsStringSync('local-only');

    await expectLater(
      mgr.sync(rec.id),
      throwsA(
        isA<DriveConflictException>().having(
          (e) => e.message,
          'message',
          allOf(contains('a.txt'), isNot(contains('c.txt'))),
        ),
      ),
    );
  });

  test(
    'a divergence does not list a file that differs only by exec bit',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      // bump.sh is mounted non-executable, so local and node agree on content
      // and bit. (Mirrors a Windows node, where the exec bit is always false.)
      File('${src.path}/bump.sh').writeAsStringSync('#!/bin/sh\necho hi\n');
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );

      // Flip only the local exec bit — content stays identical to the node.
      Process.runSync('chmod', ['+x', '${src.path}/bump.sh']);
      // Genuinely diverge another file's content on both sides to force the
      // conflict.
      File('${src.path}/a.txt').writeAsStringSync('local-edit');
      File('${remotePath()}/a.txt').writeAsStringSync('node-edit');

      await expectLater(
        mgr.sync(rec.id),
        throwsA(
          isA<DriveConflictException>().having(
            (e) => e.message,
            'message',
            allOf(contains('a.txt'), isNot(contains('bump.sh'))),
          ),
        ),
      );
    },
    // chmod is a no-op on Windows, so the exec-bit divergence cannot be set up.
    testOn: '!windows',
  );

  test(
    'drive diff reports a small text file diverging on both sides',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );

      File('${src.path}/a.txt').writeAsStringSync('local-edit');
      File('${remotePath()}/a.txt').writeAsStringSync('node-edit');

      final d = await mgr.diffFile(rec.id, 'a.txt');
      expect(d.identical, isFalse);
      expect(d.binary, isFalse);
      expect(d.tooLarge, isFalse);
      expect(utf8.decode(d.localBytes!), 'local-edit');
      expect(utf8.decode(d.originBytes!), 'node-edit');
      // Hashes differ; both sizes are recorded.
      expect(d.local!.hash, isNot(d.origin!.hash));
      // Both sides moved off the baseline: a true conflict.
      expect(d.side, FileDivergence.bothSides);
    },
  );

  test('drive diff classifies a local-only change as push-able', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // Only the local copy changes; the node still holds the first-sync version.
    File('${src.path}/a.txt').writeAsStringSync('local-edit');

    final d = await mgr.diffFile(rec.id, 'a.txt');
    expect(d.identical, isFalse);
    // Differs from the node, but it is a one-sided change, not a conflict.
    expect(d.side, FileDivergence.localOnly);

    final d2 = await mgr
        .diffFile(rec.id, 'a.txt')
        .then((d) => formatFileDiff(d));
    expect(d2, contains('Changed only locally'));
  });

  test(
    'drive conflicts lists diverging files grouped by side, no sync',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );

      // a.txt conflicts (both sides); c.txt is local-only; sub/b.txt is remote-only.
      File('${src.path}/a.txt').writeAsStringSync('local-a');
      File('${remotePath()}/a.txt').writeAsStringSync('node-a');
      File('${src.path}/c.txt').writeAsStringSync('local-only');
      File('${remotePath()}/sub/b.txt').writeAsStringSync('node-b');

      final before = mgr.get(rec.id)!.syncState.baselineRef;
      final c = await mgr.conflicts(rec.id);

      expect(c.conflicts, ['a.txt']);
      expect(c.localOnly, ['c.txt']);
      expect(c.remoteOnly, ['sub/b.txt']);
      expect(c.hasConflicts, isTrue);
      expect(c.total, 3);
      expect(c.diffs, isEmpty); // not requested
      expect(formatDriveChanges(c, mountId: rec.id), contains('a.txt'));

      // Read-only: nothing was synced or re-anchored, files are untouched.
      expect(mgr.get(rec.id)!.syncState.baselineRef, before);
      expect(File('${remotePath()}/a.txt').readAsStringSync(), 'node-a');
      expect(File('${src.path}/a.txt').readAsStringSync(), 'local-a');
      expect(File('${remotePath()}/c.txt').existsSync(), isFalse);
    },
  );

  test(
    'drive conflicts --diff includes a diff for each conflicting file',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );

      // a.txt conflicts; c.txt is local-only (should NOT get a diff).
      File('${src.path}/a.txt').writeAsStringSync('local-a');
      File('${remotePath()}/a.txt').writeAsStringSync('node-a');
      File('${src.path}/c.txt').writeAsStringSync('local-only');

      final c = await mgr.conflicts(rec.id, includeDiffs: true);
      // Only the conflicting file carries a diff.
      expect(c.diffs.keys, ['a.txt']);
      final d = c.diffs['a.txt']!;
      expect(d.side, FileDivergence.bothSides);
      expect(utf8.decode(d.localBytes!), 'local-a');
      expect(utf8.decode(d.originBytes!), 'node-a');

      // The rendered report embeds the per-file diff under the summary.
      final report = formatDriveChanges(c, mountId: rec.id);
      expect(report, contains('diff a.txt'));
      expect(report, contains('local-a'));
      expect(report, contains('node-a'));
    },
  );

  test(
    'drive conflicts --diff shows diffs even when baseline is unknown',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );
      // Legacy mount: no baseline snapshot, so paths can't be classified.
      mgr.store.mounts[rec.id] = MountRecord.fromJson(
        rec.toJson()..remove('baselineManifest'),
      );

      File('${src.path}/a.txt').writeAsStringSync('local-a');
      File('${remotePath()}/a.txt').writeAsStringSync('node-a');

      final c = await mgr.conflicts(rec.id, includeDiffs: true);
      expect(c.conflicts, isEmpty);
      expect(c.unknown, contains('a.txt'));
      // The diff is still produced for the unclassified path.
      expect(c.diffs.containsKey('a.txt'), isTrue);
      final report = formatDriveChanges(c, mountId: rec.id);
      expect(report, contains('baseline unknown'));
      expect(report, contains('diff a.txt'));
      expect(report, contains('local-a'));
      expect(report, contains('node-a'));
    },
  );

  test('drive conflicts reports a converged mount as in sync', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    final c = await mgr.conflicts(rec.id);
    expect(c.isEmpty, isTrue);
    expect(c.hasConflicts, isFalse);
  });

  test('drive diff classifies a remote-only change as pull-able', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    File('${remotePath()}/a.txt').writeAsStringSync('node-edit');

    final d = await mgr.diffFile(rec.id, 'a.txt');
    expect(d.side, FileDivergence.remoteOnly);
  });

  test('drive diff flags a binary file as size/hash only', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // A NUL byte makes both sides binary; their bytes are not transferred.
    File('${src.path}/bin.dat').writeAsBytesSync([1, 0, 2, 3]);
    File('${remotePath()}/bin.dat').writeAsBytesSync([4, 0, 5]);

    final d = await mgr.diffFile(rec.id, 'bin.dat');
    expect(d.binary, isTrue);
    expect(d.localBytes, isNull);
    expect(d.originBytes, isNull);
    expect(d.local!.size, 4);
    expect(d.origin!.size, 3);
  });

  test('drive resolve <file> accepts local for one path only', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // Two paths diverge on both sides.
    File('${src.path}/a.txt').writeAsStringSync('local-a');
    File('${remotePath()}/a.txt').writeAsStringSync('node-a');
    File('${src.path}/sub/b.txt').writeAsStringSync('local-b');
    File('${remotePath()}/sub/b.txt').writeAsStringSync('node-b');

    // Resolve only a.txt to local: the node copy is overwritten, b.txt is left
    // diverging, so the mount has not converged yet.
    final o1 = await mgr.resolveFile(rec.id, 'a.txt', strategy: 'accept-local');
    expect(o1.converged, isFalse);
    expect(File('${remotePath()}/a.txt').readAsStringSync(), 'local-a');
    expect(File('${remotePath()}/sub/b.txt').readAsStringSync(), 'node-b');

    // Resolving the last path converges the mount and re-anchors it clean.
    final o2 = await mgr.resolveFile(
      rec.id,
      'sub/b.txt',
      strategy: 'accept-origin',
    );
    expect(o2.converged, isTrue);
    expect(o2.record.syncState.status, SyncStatus.clean);
    expect(File('${src.path}/sub/b.txt').readAsStringSync(), 'node-b');

    // A subsequent auto-sync is a clean no-op, not a conflict.
    final out = await mgr.sync(rec.id);
    expect(out.isConflict, isFalse);
  });

  test('read-only mount pushes local edits and never discards them', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    // Read-only: the client is the source of truth and only ever pushes, so a
    // diverged local copy can never be discarded by an inbound pull.
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );

    // Local edits an existing file and adds a new one; the node stays put.
    File('${src.path}/a.txt').writeAsStringSync('local-edit');
    File('${src.path}/new.txt').writeAsStringSync('local-only');

    final out = await mgr.sync(rec.id);

    expect(out.direction, SyncDirection.push);
    expect(out.isConflict, isFalse);
    // Local edits survive and are published to the node, never pulled away.
    expect(File('${src.path}/a.txt').readAsStringSync(), 'local-edit');
    expect(File('${src.path}/new.txt').readAsStringSync(), 'local-only');
    expect(File('${remotePath()}/new.txt').readAsStringSync(), 'local-only');
  });

  test('auto-sync pushes a new local-only file without deleting it', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();
    final rec = await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    // Only the local side changed: a newly created file. Auto-direction must
    // push it up (not pull the origin down and delete it).
    File('${src.path}/fresh.txt').writeAsStringSync('keep-me');
    final out = await mgr.sync(rec.id);

    expect(out.direction, SyncDirection.push);
    expect(File('${src.path}/fresh.txt').readAsStringSync(), 'keep-me');
    expect(File('${remotePath()}/fresh.txt').readAsStringSync(), 'keep-me');
  });

  test('mounts read-only and rejects nothing for a clean re-sync', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final rec = await mgr.mountDirectory(
      localDir: localDir().path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );
    // Nothing changed: a re-sync is a no-op push of zero files.
    final out = await mgr.sync(rec.id);
    expect(out.isConflict, isFalse);
    expect(File('${remotePath()}/a.txt').readAsStringSync(), 'alpha');
  });

  test('transfers a large file across the credit window', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = Directory('${tmp.path}/big')..createSync();
    final rnd = Random(7);
    final bytes = Uint8List.fromList(
      List.generate(2 * 1024 * 1024, (_) => rnd.nextInt(256)),
    );
    File('${src.path}/big.bin').writeAsBytesSync(bytes);

    await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );

    expect(File('${remotePath()}/big.bin').readAsBytesSync(), bytes);
  });

  test('transfers a large compressible file intact through gzip', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = Directory('${tmp.path}/text')..createSync();
    // Highly compressible content well above the 1 KiB gzip threshold, so the
    // drive payloads are gzipped on the wire; the bytes must arrive intact.
    final text = ('the quick brown fox jumps over the lazy dog\n' * 50000);
    File('${src.path}/big.txt').writeAsStringSync(text);

    await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );

    expect(File('${remotePath()}/big.txt').readAsStringSync(), text);
  });

  test('deduplicates identical content when populating the node', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    // Two byte-identical files (plus a unique one). The sync sends the shared
    // payload once and the node copies it into the duplicate's place via the
    // server-side copy op (omnydrive 1.4.0); all three must arrive intact.
    final src = Directory('${tmp.path}/dup')..createSync();
    final shared = 'the quick brown fox\n' * 200; // above the 1 KiB threshold
    File('${src.path}/one.bin').writeAsStringSync(shared);
    File('${src.path}/two.bin').writeAsStringSync(shared);
    File('${src.path}/unique.txt').writeAsStringSync('only-me');

    await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );

    expect(File('${remotePath()}/one.bin').readAsStringSync(), shared);
    expect(File('${remotePath()}/two.bin').readAsStringSync(), shared);
    expect(File('${remotePath()}/unique.txt').readAsStringSync(), 'only-me');
  });

  test(
    'copies content already present on the node instead of resending',
    () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );
      expect(File('${remotePath()}/a.txt').readAsStringSync(), 'alpha');

      // Add a new local file whose content matches a file the node already holds.
      // The push must satisfy it via a server-side copy from the existing node
      // file rather than a byte transfer; the content must land correctly.
      File('${src.path}/a-again.txt').writeAsStringSync('alpha');
      final out = await mgr.sync(rec.id);

      expect(out.direction, SyncDirection.push);
      expect(File('${remotePath()}/a-again.txt').readAsStringSync(), 'alpha');
    },
  );

  test('mounts a git repository onto the node', () async {
    if (!await _gitAvailable()) {
      markTestSkipped('git not installed');
      return;
    }
    final origin = Directory('${tmp.path}/origin')..createSync();
    await _git(['init', '-q'], origin.path);
    await _git(['config', 'user.email', 't@example.com'], origin.path);
    await _git(['config', 'user.name', 'Test'], origin.path);
    File('${origin.path}/main.dart').writeAsStringSync('void main() {}\n');
    await _git(['add', '.'], origin.path);
    await _git(['commit', '-q', '-m', 'init'], origin.path);

    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);

    final rec = await mgr.mountGit(
      url: origin.path,
      nodeId: 'web-01',
      remotePath: '${tmp.path}/clone',
    );

    expect(rec.kind, 'git');
    expect(rec.syncState.baselineRef.value, isNotEmpty);
    expect(File('${tmp.path}/clone/main.dart').existsSync(), isTrue);
    // The node reports the checked-out branch, captured on the record.
    final head = await Process.run('git', [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ], workingDirectory: origin.path);
    expect(rec.currentBranch, (head.stdout as String).trim());
  });

  test('unmount forgets the mount', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final rec = await mgr.mountDirectory(
      localDir: localDir().path,
      nodeId: 'web-01',
      remotePath: remotePath(),
    );
    await mgr.unmount(rec.id);
    expect(mgr.get(rec.id), isNull);
    final reloaded = await DriveManager.open(client, home: home);
    expect(reloaded.get(rec.id), isNull);
  });

  group('path filter (--include/--exclude)', () {
    test('excluded sub-paths are never published to the node', () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);

      final rec = await mgr.mountDirectory(
        localDir: localDir().path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        filter: PathFilter(exclude: ['sub/**']),
      );

      // The included file lands; the excluded subtree never does.
      expect(File('${remotePath()}/a.txt').readAsStringSync(), 'alpha');
      expect(File('${remotePath()}/sub/b.txt').existsSync(), isFalse);

      // The filter survives a store reload (so remount/sync keep filtering).
      final reloaded = await DriveManager.open(client, home: home);
      expect(reloaded.get(rec.id)!.filter.exclude, ['sub/**']);
    });

    test('include acts as a whitelist', () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);

      await mgr.mountDirectory(
        localDir: localDir().path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        filter: PathFilter(include: ['sub/**']),
      );

      expect(File('${remotePath()}/sub/b.txt').readAsStringSync(), 'beta');
      expect(File('${remotePath()}/a.txt').existsSync(), isFalse);
    });

    test('editing an excluded file does not trigger a sync', () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();

      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
        filter: PathFilter(exclude: ['sub/**']),
      );

      // Touch only an excluded file: both filtered manifests are unchanged, so
      // auto-sync is a no-op and nothing is pushed.
      File('${src.path}/sub/b.txt').writeAsStringSync('beta-2');
      final out = await mgr.sync(rec.id);
      expect(out.direction, isNull);
      expect(File('${remotePath()}/sub/b.txt').existsSync(), isFalse);
    });
  });

  group('.omnyignore (resolveDirMountFilter)', () {
    test('patterns become the default exclude set', () async {
      final src = localDir();
      File(
        '${src.path}/.omnyignore',
      ).writeAsStringSync('# a comment\n\nsub/**\n!sub/b.txt\n');

      final filter = await resolveDirMountFilter(localDir: src.path);

      // The comment, blank line and negation are dropped; only "sub/**" remains.
      expect(filter, isNotNull);
      expect(filter!.exclude, ['sub/**']);
      expect(filter.include, isEmpty);
    });

    test('explicit --include/--exclude overrides the file entirely', () async {
      final src = localDir();
      File('${src.path}/.omnyignore').writeAsStringSync('sub/**\n');

      final explicit = PathFilter(include: ['a.txt']);
      final filter = await resolveDirMountFilter(
        localDir: src.path,
        explicit: explicit,
      );

      // The file is not consulted; the explicit filter passes through unchanged.
      expect(filter, same(explicit));
    });

    test('a missing or empty file yields no filter', () async {
      final src = localDir();
      expect(await resolveDirMountFilter(localDir: src.path), isNull);

      File('${src.path}/.omnyignore').writeAsStringSync('\n# only comments\n');
      expect(await resolveDirMountFilter(localDir: src.path), isNull);
    });

    test('--ignore-file selects a custom file name', () async {
      final src = localDir();
      File('${src.path}/.omnyignore').writeAsStringSync('a.txt\n');
      File('${src.path}/.dockerignore').writeAsStringSync('sub/**\n');

      final filter = await resolveDirMountFilter(
        localDir: src.path,
        ignoreFileName: '.dockerignore',
      );

      expect(filter!.exclude, ['sub/**']);
    });

    test('resolved filter publishes a mount that honors it and reuses', () async {
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();
      File('${src.path}/.omnyignore').writeAsStringSync('sub/**\n');

      final filter = await resolveDirMountFilter(localDir: src.path);
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
        filter: filter,
      );

      // The ignored subtree never reaches the node and the filter persists.
      expect(File('${remotePath()}/a.txt').readAsStringSync(), 'alpha');
      expect(File('${remotePath()}/sub/b.txt').existsSync(), isFalse);
      expect(rec.filter.exclude, ['sub/**']);

      // Reuse matching uses the same resolved filter, so a re-run reuses the
      // mount rather than re-pushing the whole tree (guards the call-site
      // resolution: the persisted record's filter equals what the lookup wants).
      final reuse = mgr.findReusableDirMount(
        nodeId: 'web-01',
        localDir: src.path,
        remotePath: remotePath(),
        filter: filter,
      );
      expect(reuse?.id, rec.id);
    });
  });
}

Future<bool> _gitAvailable() async {
  try {
    final r = await Process.run('git', ['--version']);
    return r.exitCode == 0;
  } on Object {
    return false;
  }
}

Future<void> _git(List<String> args, String cwd) async {
  final r = await Process.run('git', args, workingDirectory: cwd);
  if (r.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${r.stderr}');
  }
}
