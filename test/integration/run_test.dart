@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/src/application/client/drive/drive_manager.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Exercises the mount → run → sync-back → unmount sequence that the
/// `omnyshell run` and `omnyshell exec --mount` CLI commands orchestrate
/// (see `_execWithMount` in bin/omnyshell.dart). The CLI helper lives in the
/// executable, so these tests drive the same building blocks directly:
/// [DriveManager.mountDirectory] (push), [ClientRuntime.execute] with a `cwd`,
/// [DriveManager.sync] (pull back) and [DriveManager.unmount].
void main() {
  late TestCluster cluster;
  late Directory tmp;
  late String home;

  setUp(() async {
    cluster = await TestCluster.start();
    tmp = Directory.systemTemp.createTempSync('omnyshell-run-it');
    home = '${tmp.path}/home'; // isolates ~/.omnyshell/mounts.json
  });
  tearDown(() async {
    await cluster.dispose();
    tmp.deleteSync(recursive: true);
  });

  Directory localDir() {
    final d = Directory('${tmp.path}/src')..createSync();
    File('${d.path}/input.txt').writeAsStringSync('hello');
    return d;
  }

  String remotePath() => '${tmp.path}/remote';

  test('runs a remote command in the mount and syncs its output back', () async {
    await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);

    // Mount (push the local dir up) — read-write so node changes pull back.
    final rec = await mgr.mountDirectory(
      localDir: localDir().path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );
    expect(File('${remotePath()}/input.txt').readAsStringSync(), 'hello');

    // Run a command inside the mount that writes a new file (cwd = mount path).
    final result = await client.execute(
      nodeId: 'web-01',
      command: 'echo produced-on-node> out.txt',
      cwd: rec.remotePath,
    );
    expect(result.exitCode, 0);
    expect(File('${remotePath()}/out.txt').existsSync(), isTrue);

    // Final sync-back pulls the node's new file down to the local origin.
    final out = await mgr.sync(rec.id);
    expect(out.isConflict, isFalse);
    expect(
      File('${rec.localPath}/out.txt').readAsStringSync().trim(),
      'produced-on-node',
    );
  });

  test('mounts a directory given as "." / trailing-dot path', () async {
    // Regression: the CLI `run` defaults --dir to ".", whose absolute path ends
    // in "/.". The derived mount name must be the real directory name, not ".".
    await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();

    final rec = await mgr.mountDirectory(
      localDir: '${src.path}/.',
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );

    expect(rec.name, isNot('.'));
    expect(File('${remotePath()}/input.txt').readAsStringSync(), 'hello');
  });

  test('unmount --clean-remote tears down and wipes the node copy', () async {
    await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);

    final rec = await mgr.mountDirectory(
      localDir: localDir().path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
    );
    expect(File('${remotePath()}/input.txt').existsSync(), isTrue);

    // keepRemote: false is what `--clean-remote` maps to.
    await mgr.unmount(rec.id, keepRemote: false);

    expect(mgr.get(rec.id), isNull);
    expect(File('${remotePath()}/input.txt').existsSync(), isFalse);
    final reloaded = await DriveManager.open(client, home: home);
    expect(reloaded.get(rec.id), isNull);
  });
}
