@TestOn('vm')
@Tags(['windows'])
library;

import 'dart:io';

import 'package:omnyshell/src/application/update/installation.dart';
import 'package:omnyshell/src/version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Drives `omnyshell update` as a user would: this package activated with
/// `dart pub global activate --source path` into a throwaway pub cache, run
/// through the wrapper pub generates. Every per-user location (home, data
/// directories) points into a temporary directory too, so the machine's own
/// installation and services are never touched.
///
/// A *copy* of the package is activated: a path activation runs `pub get` in
/// the package, which would point this checkout's `.dart_tool` at the
/// throwaway cache (and break it once that is deleted).
///
/// On macOS and Linux the throwaway cache links its `hosted`/`git` folders to
/// the real cache, so that `pub get` resolves offline, while
/// `global_packages` and `bin` stay throwaway. Not on Windows: a link to a
/// directory is a junction there, and deleting the throwaway cache went
/// through it and emptied the real cache (CI then failed to load other tests
/// for missing packages). There the throwaway cache downloads what it needs.
///
/// Tagged `windows` so the Windows CI job runs it as well (through the
/// `.bat` wrapper pub writes there).
void main() {
  final dart = Platform.resolvedExecutable;
  final checkout = Directory.current.path;
  late Directory tmp;
  late String package;
  late Map<String, String> env;
  late String wrapper;
  final links = <Link>[];

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('omny_update_it_');
    final home = Directory(p.join(tmp.path, 'home'))..createSync();

    package = p.join(tmp.path, 'omnyshell');
    Directory(package).createSync();
    for (final name in ['pubspec.yaml', 'pubspec.lock']) {
      File(p.join(checkout, name)).copySync(p.join(package, name));
    }
    for (final dir in ['lib', 'bin']) {
      _copyTree(Directory(p.join(checkout, dir)), p.join(package, dir));
    }

    final cache = Directory(p.join(tmp.path, 'pub-cache'))..createSync();
    if (!Platform.isWindows) {
      final realCache = defaultPubCache();
      for (final shared in ['hosted', 'git']) {
        final target = Directory(p.join(realCache, shared));
        if (!target.existsSync()) continue;
        links.add(Link(p.join(cache.path, shared))..createSync(target.path));
      }
    }

    env = {
      'PUB_CACHE': cache.path,
      'HOME': home.path,
      'USERPROFILE': home.path,
      'XDG_DATA_HOME': p.join(home.path, '.local', 'share'),
      // Windows: the service registry and dart install live here. The real
      // APPDATA/LOCALAPPDATA would reach the machine's own.
      'LOCALAPPDATA': p.join(home.path, 'AppData', 'Local'),
      'APPDATA': p.join(home.path, 'AppData', 'Roaming'),
      'OMNYSHELL_HOME': p.join(home.path, '.omnyshell'),
    };
    final activate = await Process.run(dart, [
      'pub',
      'global',
      'activate',
      '--source',
      'path',
      package,
    ], environment: env);
    expect(
      activate.exitCode,
      0,
      reason: '${activate.stdout}${activate.stderr}',
    );
    wrapper = p.join(
      env['PUB_CACHE']!,
      'bin',
      Platform.isWindows ? 'omnyshell.bat' : 'omnyshell',
    );
    expect(File(wrapper).existsSync(), isTrue);
  });

  tearDownAll(() async {
    // The links first, on their own — judged by what they are, not what they
    // point to — so the real cache behind them stays.
    for (final link in links) {
      if (FileSystemEntity.typeSync(link.path, followLinks: false) ==
          FileSystemEntityType.link) {
        link.deleteSync();
      }
    }
    // Should any link have survived, a recursive delete could reach the real
    // cache through it: leave the temporary directory instead.
    final survivors = links.where(
      (l) =>
          FileSystemEntity.typeSync(l.path, followLinks: false) !=
          FileSystemEntityType.notFound,
    );
    if (survivors.isNotEmpty) return;
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Best-effort: Windows may still hold a just-exited process's files.
    }
  });

  Future<ProcessResult> omnyshell(List<String> args) => Process.run(
    wrapper,
    args,
    environment: env,
    runInShell: Platform.isWindows, // the .bat wrapper
  ).timeout(const Duration(minutes: 3));

  /// Runs `bin/omnyshell.dart` of [root] (default: this checkout) with the
  /// Dart VM, as `dart run` does.
  Future<ProcessResult> fromSource(
    List<String> args, {
    String? root,
    Map<String, String> overrides = const {},
  }) => Process.run(
    dart,
    [p.join(root ?? checkout, 'bin', 'omnyshell.dart'), ...args],
    environment: {...env, ...overrides},
  ).timeout(const Duration(minutes: 3));

  test('--check reports the path installation and changes nothing', () async {
    final r = await omnyshell(['update', '--check']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(
      r.stdout,
      contains(
        'Installed: omnyshell $omnyShellVersion, via `dart pub global '
        'activate` from local path',
      ),
    );
    expect(r.stdout, contains('no version list'));
    expect(r.stdout, isNot(contains('Will run')));
  });

  test('--dry-run shows the re-activation, and runs nothing', () async {
    final r = await omnyshell(['update', '--dry-run', '--force']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(r.stdout, contains('Will run:'));
    expect(r.stdout, contains('pub global activate --source path'));
    expect(r.stdout, isNot(contains('Now:')));
  });

  test('--to is refused for a path installation', () async {
    final r = await omnyshell(['update', '--to', '1.0.0', '--yes']);
    expect(r.exitCode, isNot(0));
    expect('${r.stderr}${r.stdout}', contains('--to needs a package from'));
  });

  test('a real update re-activates and runs the new binary', () async {
    final r = await omnyshell(['update', '--force', '--yes']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(r.stdout, contains('Activated omnyshell $omnyShellVersion'));
    expect(r.stdout, contains('Now:       omnyshell $omnyShellVersion'));
    // No services in this throwaway home: none to refresh.
    expect(r.stdout, isNot(contains('Services:')));
  });

  test(
    'run from a checkout, it is not an installation it can update',
    () async {
      // This checkout is not the activated package (its copy is).
      final r = await fromSource(['update', '--check']);
      expect(r.exitCode, isNot(0));
      expect('${r.stderr}', contains('cannot be updated in place'));
    },
  );

  test('the activated package run from source is that installation', () async {
    // `dart pub global run` of a path activation runs the package itself;
    // only the activation record in the pub cache identifies it.
    final r = await fromSource(['update', '--check'], root: package);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    // Pub records the path in its own form — resolved on macOS (/var →
    // /private/var), 8.3-shortened on Windows (RUNNER~1) — so only the unique
    // tail is compared.
    expect(
      r.stdout,
      matches(
        RegExp(
          'from local path .*'
          '${RegExp.escape(p.join(p.basename(tmp.path), 'omnyshell'))}',
        ),
      ),
    );
  });

  group('the service refresh worker', () {
    test('reports, and logs, a service that is not installed', () async {
      // `node`, with this test's empty registry (HOME/LOCALAPPDATA above).
      final log = p.join(tmp.path, 'worker.log');
      final r = await fromSource([
        'update',
        '--refresh-services',
        'node',
        '--log',
        log,
      ]);
      expect(r.exitCode, isNot(0));
      expect(r.stdout, contains('"node" is not installed'));
      expect(File(log).readAsStringSync(), contains('"node" is not installed'));
    });

    test('--detach returns at once and the detached run logs', () async {
      // A role no machine has: on Windows the detached run is created by WMI
      // with the user's own environment (not this test's), so it reads the
      // real service registry — and must find nothing to touch there.
      const role = 'omny-test-no-such-role';
      final log = p.join(tmp.path, 'detached.log');
      final r = await fromSource([
        'update',
        '--refresh-services',
        role,
        '--detach',
        '--log',
        log,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, contains('in the background'));
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!(File(log).existsSync() &&
              File(log).readAsStringSync().contains('"$role"')) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(
        File(log).readAsStringSync(),
        contains('"$role" is not installed'),
      );
    });

    test('an unwritable log does not fail the refresh itself', () async {
      // A directory where the log file should be: every append fails.
      final log = Directory(p.join(tmp.path, 'log-is-a-dir'))..createSync();
      final r = await fromSource([
        'update',
        '--refresh-services',
        'omny-test-no-such-role',
        '--log',
        log.path,
      ]);
      expect(r.stderr, contains('cannot write ${log.path}'));
      // Reported once, and the refresh's own outcome still decides the exit.
      expect('cannot write'.allMatches('${r.stderr}'), hasLength(1));
      expect(r.stdout, contains('is not installed'));
      expect(r.stderr, contains('not refreshed: omny-test-no-such-role'));
    });
  });

  group('a hosted installation', () {
    // A kernel snapshot of this package where `dart pub global activate`
    // puts one, and a lock naming a repository that does not answer: the
    // hosted flow, without pub.dev (or any network).
    late String snapshot;
    late Map<String, String> hostedEnv;

    setUpAll(() async {
      final cache = p.join(tmp.path, 'hosted-cache');
      final root = p.join(cache, 'global_packages', 'omnyshell');
      Directory(p.join(root, 'bin')).createSync(recursive: true);
      File(p.join(root, 'pubspec.lock')).writeAsStringSync('''
packages:
  omnyshell:
    dependency: "direct main"
    description:
      name: omnyshell
      sha256: "0"
      url: "http://127.0.0.1:9"
    source: hosted
    version: "$omnyShellVersion"
''');
      snapshot = p.join(root, 'bin', 'omnyshell.dart-test.snapshot');
      final compile = await Process.run(dart, [
        'compile',
        'kernel',
        p.join(checkout, 'bin', 'omnyshell.dart'),
        '-o',
        snapshot,
      ]).timeout(const Duration(minutes: 5));
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      hostedEnv = {...env, 'PUB_CACHE': cache};
    });

    Future<ProcessResult> hosted(List<String> args) => Process.run(dart, [
      snapshot,
      ...args,
    ], environment: hostedEnv).timeout(const Duration(minutes: 3));

    test('is detected, with its repository', () async {
      final r = await hosted(['update', '--check']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(
        r.stdout,
        contains('via `dart pub global activate` from http://127.0.0.1:9'),
      );
      expect(r.stdout, contains('Latest:    unknown'));
      expect(r.stdout, contains('Could not tell whether an update'));
    });

    test('does not reinstall blindly when the latest is unknown', () async {
      final r = await hosted(['update', '--yes']);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('could not tell the latest version'));
      expect(r.stdout, isNot(contains('Will run')));
    });

    test('--to targets a version from the same repository', () async {
      final r = await hosted(['update', '--to', '1.0.0', '--dry-run']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(
        r.stdout,
        contains(
          'pub global activate omnyshell 1.0.0 --hosted-url '
          'http://127.0.0.1:9',
        ),
      );
    });
  });
}

/// Copies the directory tree [from] to [to].
void _copyTree(Directory from, String to) {
  for (final entity in from.listSync(recursive: true, followLinks: false)) {
    final target = p.join(to, p.relative(entity.path, from: from.path));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      entity.copySync(target);
    }
  }
}
