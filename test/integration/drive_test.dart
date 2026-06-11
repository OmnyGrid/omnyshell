@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:omnydrive/omnydrive.dart' show SyncDirection;
import 'package:omnyshell/src/application/client/drive/drive_manager.dart';
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

      // Auto-direction refuses to guess rather than destroying either side.
      await expectLater(
        mgr.sync(rec.id),
        throwsA(isA<DriveConflictException>()),
      );
      // The local copy is preserved, not clobbered by a pull.
      expect(File('${src.path}/a.txt').readAsStringSync(), 'local-edit');
    },
  );

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
