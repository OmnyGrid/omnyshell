@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Drives `:drive` end to end through the local-command registry against a real
/// Hub + node: mounting, status, sync, divergence inspection and resolution,
/// remount, unmount and background watching. The mount store lives under a
/// per-test temp home (`addFileTransferCommands(driveHome: …)`), so nothing
/// touches the user's `~/.omnyshell/mounts.json`.
void main() {
  late TestCluster cluster;
  late ClientRuntime client;
  late Directory tmp;
  late List<String> out;
  late StreamController<String> lines;
  late LocalCommandRegistry registry;

  setUp(() async {
    cluster = await TestCluster.start();
    await cluster.startNode(id: 'web-01');
    client = await cluster.connectClient();
    tmp = Directory.systemTemp.createTempSync('omnyshell-drive-cmd-');
    out = [];
    lines = StreamController<String>.broadcast();
    registry = LocalCommandRegistry.withDefaults()
      ..addFileTransferCommands(driveHome: '${tmp.path}/home');
  });

  tearDown(() async {
    // Stop any background watcher before the cluster goes away.
    await registry.handle(':drive unwatch', _context('web-01', (_) {}));
    await cluster.dispose();
    await lines.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void record(String line) {
    out.add(line);
    if (!lines.isClosed) lines.add(line);
  }

  /// Runs [line] as a local command in a session on [nodeId].
  Future<void> run(String line, {String nodeId = 'web-01'}) async {
    final handled = await registry.handle(
      line,
      _context(nodeId, record, client: client),
    );
    expect(handled, isTrue, reason: '$line should be a local command');
  }

  /// Waits until a line captured at or after index [from] satisfies [test]
  /// (already seen, or the next one to arrive), for output a background
  /// watcher prints later.
  Future<void> waitFor(bool Function(String line) test, {int from = 0}) async {
    if (out.skip(from).any(test)) return;
    await lines.stream.firstWhere(test).timeout(const Duration(seconds: 30));
  }

  /// Starts watching [id] and waits for the watcher's initial sync to finish.
  Future<void> watch(String id, [String flags = '']) async {
    await run(':drive watch $id$flags');
    await waitFor((l) => l == 'drive[$id]: watching $id (Ctrl-C to stop)');
  }

  String output() => out.join('\n');

  /// The mount id from the last `Mounted <id>` line.
  String mountedId() =>
      out.lastWhere((l) => l.startsWith('Mounted ')).substring(8);

  /// A local directory with `a.txt` and `sub/b.txt`.
  Directory localDir() {
    final d = Directory('${tmp.path}/src')..createSync();
    File('${d.path}/a.txt').writeAsStringSync('alpha');
    Directory('${d.path}/sub').createSync();
    File('${d.path}/sub/b.txt').writeAsStringSync('beta');
    return d;
  }

  String remote() => '${tmp.path}/remote';

  /// Mounts [localDir] onto [remote] and returns the mount id.
  Future<String> mount({bool rw = false, String extra = ''}) async {
    await run(
      ':drive mount ${localDir().path} ${remote()}${rw ? ' --rw' : ''}$extra',
    );
    final id = mountedId();
    out.clear();
    return id;
  }

  group(':drive mount / ls / status', () {
    test('mounts a directory, reporting progress and the mount row', () async {
      final src = localDir();

      await run(':drive mount ${src.path} ${remote()} --name docs');

      final id = mountedId();
      expect(File('${remote()}/a.txt').readAsStringSync(), 'alpha');
      expect(File('${remote()}/sub/b.txt').readAsStringSync(), 'beta');
      // Per-file progress lines precede the result.
      expect(out, contains(startsWith('↑ ')));
      final row = out.last;
      expect(row, startsWith('  $id'));
      expect(row, contains('ro  ${src.path} -> ${remote()}'));
      // The record persisted under the temp home, not the user's.
      expect(
        File('${tmp.path}/home/.omnyshell/mounts.json').existsSync(),
        true,
      );
    });

    test('ls lists only this node\'s mounts', () async {
      final id = await mount(rw: true);

      await run(':drive ls');
      expect(out, hasLength(1));
      expect(out.single, startsWith(id));
      expect(out.single, contains('rw  '));

      out.clear();
      await run(':drive list', nodeId: 'other-node');
      expect(out, ['No mounts on this node.']);
    });

    test('status describes the mount', () async {
      final id = await mount();

      await run(':drive status $id');

      expect(out[0], 'Mount:    $id');
      expect(out[1], 'Kind:     dir (read-only)');
      expect(out[2], 'Source:   ${tmp.path}/src');
      expect(out[3], 'Target:   web-01:${remote()}');
      expect(out[4], startsWith('Status:   '));
      expect(out[5], startsWith('Baseline: '));
      expect(out[6], startsWith('Synced:   '));
    });

    test('a mount on another node is refused from this session', () async {
      final id = await mount();

      await run(':drive status $id', nodeId: 'other-node');

      expect(out, [
        'drive: mount $id is on node web-01, not this session\'s node '
            '(other-node).',
      ]);
    });

    test('a missing local directory is reported', () async {
      await run(':drive mount ${tmp.path}/nope ${remote()}');

      expect(out, ['drive: local directory not found: ${tmp.path}/nope']);
    });

    test('--no-initial-sync leaves the node path empty', () async {
      await run(
        ':drive mount ${localDir().path} ${remote()} --no-initial-sync '
        '--exclude sub/**',
      );

      expect(output(), contains('Mounted '));
      expect(File('${remote()}/a.txt').existsSync(), isFalse);
    });
  });

  group(':drive sync', () {
    test('an unchanged read-only mount pushes nothing', () async {
      final id = await mount();

      await run(':drive sync $id');

      // Read-only mounts always sync by pushing the local copy.
      expect(out.last, 'Synced push: 0 change(s).');
    });

    test('an unchanged read-write mount is already up to date', () async {
      final id = await mount(rw: true);

      await run(':drive sync $id');

      expect(out.last, 'Already up to date.');
    });

    test('pushes local edits (auto and --push)', () async {
      final id = await mount();
      File('${tmp.path}/src/a.txt').writeAsStringSync('ALPHA-2');

      await run(':drive sync $id');

      expect(out.last, startsWith('Synced push: '));
      expect(File('${remote()}/a.txt').readAsStringSync(), 'ALPHA-2');

      File('${tmp.path}/src/c.txt').writeAsStringSync('gamma');
      out.clear();
      await run(':drive sync $id --push');
      expect(out.last, startsWith('Synced push: '));
      expect(File('${remote()}/c.txt').readAsStringSync(), 'gamma');
    });

    test('--pull brings node edits down on a read-write mount', () async {
      final id = await mount(rw: true);
      File('${remote()}/a.txt').writeAsStringSync('from-node');

      await run(':drive sync $id --pull');

      expect(out.last, startsWith('Synced pull: '));
      expect(File('${tmp.path}/src/a.txt').readAsStringSync(), 'from-node');
    });

    test('a two-sided change is refused, keeping the local copy', () async {
      final id = await mount(rw: true);
      File('${tmp.path}/src/a.txt').writeAsStringSync('local-edit');
      File('${remote()}/a.txt').writeAsStringSync('node-edit');

      await run(':drive sync $id');

      expect(out.last, startsWith('drive: '));
      expect(out.last, contains('a.txt'));
      expect(File('${tmp.path}/src/a.txt').readAsStringSync(), 'local-edit');
    });
  });

  group(':drive diff / conflicts / resolve', () {
    /// A read-write mount whose `a.txt` changed on both sides.
    Future<String> diverged() async {
      final id = await mount(rw: true);
      File('${tmp.path}/src/a.txt').writeAsStringSync('local-edit\n');
      File('${remote()}/a.txt').writeAsStringSync('node-edit\n');
      return id;
    }

    test('diff shows both sides of a file', () async {
      final id = await diverged();

      await run(':drive diff $id a.txt');

      final text = output();
      expect(text, startsWith('diff a.txt'));
      expect(text, contains('local-edit'));
      expect(text, contains('node-edit'));
    });

    test('conflicts lists the diverging path, with --diff inline', () async {
      final id = await diverged();

      await run(':drive conflicts $id');
      expect(output(), contains('mount $id: 1 diverging path'));
      expect(output(), contains('! a.txt'));

      out.clear();
      await run(':drive conflicts $id --diff');
      expect(output(), contains('diff a.txt'));
      expect(output(), contains('node-edit'));
    });

    test('conflicts on a converged mount says it is in sync', () async {
      final id = await mount();

      await run(':drive conflicts $id');

      expect(out, ['mount $id: in sync — no differences.']);
    });

    test('resolve <file> --accept-origin takes the node copy', () async {
      final id = await diverged();

      await run(':drive resolve $id a.txt --accept-origin');

      expect(out.last, 'Resolved a.txt (accept-origin). Mount is now in sync.');
      expect(File('${tmp.path}/src/a.txt').readAsStringSync(), 'node-edit\n');
    });

    test('resolve <file> reports other paths still diverging', () async {
      final id = await diverged();
      File('${tmp.path}/src/sub/b.txt').writeAsStringSync('local-b\n');
      File('${remote()}/sub/b.txt').writeAsStringSync('node-b\n');

      await run(':drive resolve $id a.txt');

      expect(
        out.last,
        'Resolved a.txt (accept-local). Other paths still diverge.',
      );
      expect(File('${remote()}/a.txt').readAsStringSync(), 'local-edit\n');
    });

    test('resolve --reclone cannot target a single file', () async {
      final id = await diverged();

      await run(':drive resolve $id a.txt --reclone');

      expect(out, ['drive: --reclone cannot be combined with a file path']);
    });

    test('resolve (whole mount) accepts local by default', () async {
      final id = await diverged();

      await run(':drive resolve $id');

      expect(out.last, matches(RegExp(r'^Resolved \(accept-local\): \d+ ')));
      expect(File('${remote()}/a.txt').readAsStringSync(), 'local-edit\n');
    });
  });

  group(':drive remount / unmount', () {
    test('remount re-establishes the mount', () async {
      final id = await mount();
      Directory(remote()).deleteSync(recursive: true);

      await run(':drive remount $id');

      expect(out.last, 'Remounted $id.');
      expect(File('${remote()}/a.txt').readAsStringSync(), 'alpha');
    });

    test('unmount --sync-first pushes, then forgets the mount', () async {
      final id = await mount();
      File('${tmp.path}/src/a.txt').writeAsStringSync('final');

      await run(':drive unmount $id --sync-first');

      expect(out.last, 'Unmounted $id.');
      expect(File('${remote()}/a.txt').readAsStringSync(), 'final');
      out.clear();
      await run(':drive ls');
      expect(out, ['No mounts on this node.']);
    });

    test('unmount --no-keep-remote deletes the node copy', () async {
      final id = await mount();

      await run(':drive unmount $id --no-keep-remote');

      expect(out.last, 'Unmounted $id.');
      expect(File('${remote()}/a.txt').existsSync(), isFalse);
      expect(File('${remote()}/sub/b.txt').existsSync(), isFalse);
      // The local source is never touched.
      expect(File('${tmp.path}/src/a.txt').existsSync(), isTrue);
    });
  });

  group(':drive watch / unwatch', () {
    test('watches in the background and syncs local edits', () async {
      final id = await mount();

      await watch(id, ' --interval 1 --debounce=50');
      expect(
        out,
        contains(
          'Watching $id in the background '
          '(stop with :drive unwatch $id).',
        ),
      );

      // A second watch on the same mount is refused.
      await run(':drive watch $id');
      expect(
        out.last,
        'drive: already watching $id '
        '(stop with :drive unwatch $id).',
      );

      // Only a sync logged after the edit counts (the initial one also pushes).
      final mark = out.length;
      File('${tmp.path}/src/a.txt').writeAsStringSync('watched');
      await waitFor(
        (l) => RegExp(
          '^drive\\[$id\\]: synced push \\((fs|poll)\\): [1-9]',
        ).hasMatch(l),
        from: mark,
      );
      expect(File('${remote()}/a.txt').readAsStringSync(), 'watched');

      await run(':drive unwatch other');
      expect(out.last, 'drive: not watching other.');
      await run(':drive unwatch $id');
      expect(out.last, 'Stopped watching $id.');
      await run(':drive unwatch');
      expect(out.last, 'drive: no background watchers running.');
    });

    test('unwatch with no id stops every watcher', () async {
      final id = await mount();
      await watch(id);

      await run(':drive unwatch');

      expect(out.last, 'Stopped watching $id.');
    });

    test('unmount stops the watcher silently', () async {
      final id = await mount();
      await watch(id);

      await run(':drive unmount $id');
      expect(out.last, 'Unmounted $id.');

      await run(':drive unwatch');
      expect(out.last, 'drive: no background watchers running.');
    });
  });

  group(':drive mount --git', () {
    test('clones a repository onto the node', () async {
      if (!await _gitAvailable()) {
        markTestSkipped('git not installed');
        return;
      }
      final origin = Directory('${tmp.path}/origin')..createSync();
      await _git(['init', '-q', '-b', 'main'], origin.path);
      await _git(['config', 'user.email', 't@example.com'], origin.path);
      await _git(['config', 'user.name', 'Test'], origin.path);
      File('${origin.path}/main.dart').writeAsStringSync('void main() {}\n');
      await _git(['add', '.'], origin.path);
      await _git(['commit', '-q', '-m', 'init'], origin.path);

      await run(
        ':drive mount --git ${origin.path} ${tmp.path}/clone '
        '--branch main --name app',
      );

      final id = mountedId();
      expect(out.last, contains('ro  ${origin.path} -> ${tmp.path}/clone'));
      // Coarse git phases show as `<message>…` progress lines.
      expect(out, contains(endsWith('…')));
      expect(File('${tmp.path}/clone/main.dart').existsSync(), isTrue);

      out.clear();
      await run(':drive status $id');
      expect(out[1], 'Kind:     git (read-only)');
      expect(out[2], 'Source:   ${origin.path}');
    });
  });
}

/// A session context on [nodeId] that writes output through [write].
LocalCommandContext _context(
  String nodeId,
  void Function(String) write, {
  ClientRuntime? client,
}) => LocalCommandContext(
  client: client,
  node: NodeDescriptor(
    id: NodeId(nodeId),
    displayName: nodeId,
    platform: const PlatformInfo(
      os: 'linux',
      arch: 'x64',
      agentVersion: '1.0.0',
      hostname: 'host',
    ),
    online: true,
  ),
  startedAt: DateTime.now(),
  writeLine: write,
);

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
