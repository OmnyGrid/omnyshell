@TestOn('vm')
library;

import 'dart:io';

import 'package:omnydrive/omnydrive.dart' show PathFilter, loadOmnyIgnore;
import 'package:omnyshell/src/application/client/drive/drive_manager.dart';
import 'package:omnyshell/src/application/client/drive/workspace_layout.dart';
import 'package:path/path.dart' as p;
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

  test(
    'reuses a prior ephemeral mount for the same node + local dir',
    () async {
      await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();

      // Nothing to reuse yet.
      expect(
        mgr.findReusableDirMount(nodeId: 'web-01', localDir: src.path),
        isNull,
      );

      // An ephemeral `run`-style mount.
      final rec = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
        ephemeral: true,
      );

      // The same dir reuses it — including a trailing-dot ("." / "./") form.
      expect(
        mgr.findReusableDirMount(nodeId: 'web-01', localDir: src.path)?.id,
        rec.id,
      );
      expect(
        mgr
            .findReusableDirMount(nodeId: 'web-01', localDir: '${src.path}/.')
            ?.id,
        rec.id,
      );
      // A different node never matches.
      expect(
        mgr.findReusableDirMount(nodeId: 'web-09', localDir: src.path),
        isNull,
      );
    },
  );

  test(
    "reusing a mount mirrors local onto the node and leaves local untouched",
    () async {
      // First sync of a reused mount is authoritative local→remote: the node is
      // made to match the local tree (reusing files already there) without
      // pulling, modifying, or deleting anything locally — even if the remote
      // diverged since the previous session.
      await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir(); // input.txt = 'hello'

      // Initial ephemeral mount pushes the local dir up.
      await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
        ephemeral: true,
      );
      expect(File('${remotePath()}/input.txt').readAsStringSync(), 'hello');

      // Diverge both sides between sessions: the remote gains an extra file and
      // edits input.txt; the local copy gains a new file (and keeps 'hello').
      File('${remotePath()}/remote-only.txt').writeAsStringSync('on-node');
      File('${remotePath()}/input.txt').writeAsStringSync('remote-edit');
      File('${src.path}/local-new.txt').writeAsStringSync('local');

      // Reuse path: authoritative local→remote mirror.
      final existing = mgr.findReusableDirMount(
        nodeId: 'web-01',
        localDir: src.path,
      );
      expect(existing, isNotNull);
      final o = await mgr.pushLocalMirror(existing!.id);
      expect(o.isConflict, isFalse);

      // The node now mirrors local exactly: local edits win, local-only files
      // appear, and the remote-only file is deleted.
      expect(File('${remotePath()}/input.txt').readAsStringSync(), 'hello');
      expect(File('${remotePath()}/local-new.txt').readAsStringSync(), 'local');
      expect(File('${remotePath()}/remote-only.txt').existsSync(), isFalse);

      // The local directory is untouched: nothing pulled, nothing deleted.
      expect(File('${src.path}/input.txt').readAsStringSync(), 'hello');
      expect(File('${src.path}/local-new.txt').existsSync(), isTrue);
      expect(File('${src.path}/remote-only.txt').existsSync(), isFalse);
    },
  );

  test(
    'ephemeral lookup skips a fixed --mount-path mount; explicit path matches',
    () async {
      await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);
      final src = localDir();

      // A non-ephemeral (explicit --mount-path) mount.
      final fixed = await mgr.mountDirectory(
        localDir: src.path,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
      );

      // An ephemeral run must NOT reuse the fixed-path mount...
      expect(
        mgr.findReusableDirMount(nodeId: 'web-01', localDir: src.path),
        isNull,
      );
      // ...but an explicit --mount-path matching its node path does.
      expect(
        mgr
            .findReusableDirMount(
              nodeId: 'web-01',
              localDir: src.path,
              remotePath: remotePath(),
            )
            ?.id,
        fixed.id,
      );
      // A different explicit path does not match.
      expect(
        mgr.findReusableDirMount(
          nodeId: 'web-01',
          localDir: src.path,
          remotePath: '${tmp.path}/other',
        ),
        isNull,
      );
    },
  );

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

  test(
    'run --with co-mounts a sibling under a wrapper, reachable by ../dep',
    () async {
      // Mirrors `omnyshell run <node> "..." --dir parent/x --with ../dep`:
      // the CLI mounts the nearest common ancestor (parent), filters the sync to
      // just the named members, and runs with cwd = <mount>/x so that the same
      // relative path the local code uses (../dep) resolves on the node.
      final parent = Directory('${tmp.path}/parent')..createSync();
      final x = Directory('${parent.path}/x')..createSync();
      File('${x.path}/input.txt').writeAsStringSync('hello');
      final dep = Directory('${parent.path}/dep')..createSync();
      File('${dep.path}/marker.txt').writeAsStringSync('from-dep');
      // Sibling clutter inside the wrapper that must never be synced.
      File('${parent.path}/ignored.txt').writeAsStringSync('noise');

      final layout = computeWorkspaceLayout(x.path, [dep.path]);
      // `computeWorkspaceLayout` normalizes separators (e.g. `\` on Windows),
      // while `parent.path` keeps the literal `/` from interpolation above;
      // compare the paths semantically rather than byte-for-byte.
      expect(p.equals(layout.wrapper, parent.path), isTrue);
      expect(layout.cwdSubPath, 'x');

      await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
      final client = await cluster.connectClient();
      final mgr = await DriveManager.open(client, home: home);

      final rec = await mgr.mountDirectory(
        localDir: layout.wrapper,
        nodeId: 'web-01',
        remotePath: remotePath(),
        readWrite: true,
        filter: PathFilter(include: layout.include, exclude: const []),
      );

      // Both named members land under the wrapper; the clutter does not.
      expect(File('${remotePath()}/x/input.txt').existsSync(), isTrue);
      expect(File('${remotePath()}/dep/marker.txt').existsSync(), isTrue);
      expect(File('${remotePath()}/ignored.txt').existsSync(), isFalse);

      // Run with cwd = <mount>/x and reach the sibling by its local relative
      // path — exactly what `run --with` wires up via remoteCwdSubPath. The
      // command is POSIX (`cat`) and `run` uses the node's default exec shell,
      // which is `cmd.exe` on a Windows node; assert the cwd/relative-path wiring
      // where that default is a POSIX shell. The layout, co-mount and ignore
      // behaviour above is still exercised on every platform.
      if (!Platform.isWindows) {
        final cwd = p.posix.join(rec.remotePath, layout.cwdSubPath);
        final result = await client.execute(
          nodeId: 'web-01',
          command: 'cat ../dep/marker.txt',
          cwd: cwd,
        );
        expect(result.exitCode, 0);
        expect(result.stdoutText.trim(), 'from-dep');
      }
    },
  );

  test("run --with honors a dependency's nested .omnyignore", () async {
    // Mirrors `omnyshell run <node> "..." --dir parent/x --with ../dep` where
    // dep carries `.omnyignore` excluding `*.dill`: the CLI applies each
    // member's ignore file, scoped to its subtree, on top of the whitelist.
    final parent = Directory('${tmp.path}/parent')..createSync();
    final x = Directory('${parent.path}/x')..createSync();
    File('${x.path}/main.dart').writeAsStringSync('void main() {}');
    final dep = Directory('${parent.path}/dep')..createSync();
    File('${dep.path}/.omnyignore').writeAsStringSync('*.exe\n*.dill\n');
    File('${dep.path}/lib.dart').writeAsStringSync('// source');
    Directory('${dep.path}/bin').createSync();
    // The artifact in a SUBDIRECTORY that `*.dill` must still exclude.
    File('${dep.path}/bin/server.dill').writeAsStringSync('binary');

    final layout = computeWorkspaceLayout(x.path, [dep.path]);

    // Build the filter exactly as RunCommand.run() does for --with.
    final excludes = <String>[];
    for (final memberAbs in [x.path, dep.path]) {
      final patterns = await loadOmnyIgnore(memberAbs);
      if (patterns.isEmpty) continue;
      final rel = p
          .relative(memberAbs, from: layout.wrapper)
          .replaceAll(r'\', '/');
      excludes.addAll(rel == '.' ? patterns : PathFilter.scope(rel, patterns));
    }
    expect(excludes, ['dep/**/*.exe', 'dep/**/*.dill']);

    await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);

    await mgr.mountDirectory(
      localDir: layout.wrapper,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
      filter: PathFilter(include: layout.include, exclude: excludes),
    );

    // Source files sync; the nested .dill is excluded by dep/.omnyignore.
    expect(File('${remotePath()}/x/main.dart').existsSync(), isTrue);
    expect(File('${remotePath()}/dep/lib.dart').existsSync(), isTrue);
    expect(File('${remotePath()}/dep/bin/server.dill').existsSync(), isFalse);
  });

  test('changing the --with filter is not reused as a stale mount', () async {
    await cluster.startNode(id: 'web-01', labels: {'allow-roles': 'admin'});
    final client = await cluster.connectClient();
    final mgr = await DriveManager.open(client, home: home);
    final src = localDir();

    final filtered = PathFilter(include: const ['a/**'], exclude: const []);
    await mgr.mountDirectory(
      localDir: src.path,
      nodeId: 'web-01',
      remotePath: remotePath(),
      readWrite: true,
      ephemeral: true,
      filter: filtered,
    );

    // Same node + dir but a different (or absent) filter must not reuse it.
    expect(
      mgr.findReusableDirMount(nodeId: 'web-01', localDir: src.path),
      isNull,
    );
    expect(
      mgr.findReusableDirMount(
        nodeId: 'web-01',
        localDir: src.path,
        filter: PathFilter(include: const ['b/**'], exclude: const []),
      ),
      isNull,
    );
    // The matching filter reuses it.
    expect(
      mgr
          .findReusableDirMount(
            nodeId: 'web-01',
            localDir: src.path,
            filter: filtered,
          )
          ?.remotePath,
      remotePath(),
    );
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
