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
/// throwaway cache (and break it once that is deleted). The throwaway cache
/// links its `hosted`/`git` folders to the real cache, so that `pub get`
/// resolves offline, while `global_packages` and `bin` stay throwaway.
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
    final realCache = defaultPubCache();
    for (final shared in ['hosted', 'git']) {
      final target = Directory(p.join(realCache, shared));
      if (!target.existsSync()) continue;
      links.add(Link(p.join(cache.path, shared))..createSync(target.path));
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
    // The links first, on their own: the real cache behind them stays.
    for (final link in links) {
      if (link.existsSync()) link.deleteSync();
    }
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
    // As pub records it: resolved (macOS's temp dir is under /var → /private).
    expect(
      r.stdout,
      contains(
        'from local path ${Directory(package).resolveSymbolicLinksSync()}',
      ),
    );
  });

  group('the service refresh worker', () {
    test('reports, and logs, a service that is not installed', () async {
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
      final log = p.join(tmp.path, 'detached.log');
      final r = await fromSource([
        'update',
        '--refresh-services',
        'hub',
        '--detach',
        '--log',
        log,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, contains('in the background'));
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!(File(log).existsSync() &&
              File(log).readAsStringSync().contains('"hub"')) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(File(log).readAsStringSync(), contains('"hub" is not installed'));
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
