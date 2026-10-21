import 'dart:io';

import 'package:omnyshell/src/application/update/installation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _hostedLock = '''
packages:
  omnyshell:
    dependency: "direct main"
    description:
      name: omnyshell
      sha256: "abc"
      url: "https://pub.dev"
    source: hosted
    version: "1.63.3"
''';

const _gitLock = '''
packages:
  omnyshell:
    dependency: "direct main"
    description:
      path: "packages/omnyshell"
      ref: main
      resolved-ref: "0123abcd"
      url: "https://github.com/OmnyGrid/omnyshell.git"
    source: git
    version: "1.64.0"
''';

String _pathLock(String path) =>
    '''
packages:
  omnyshell:
    dependency: "direct main"
    description:
      path: "${path.replaceAll(r'\', r'\\')}"
      relative: false
    source: path
    version: "1.64.0-dev"
''';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('omny_update_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File touch(String relative, [String content = '']) =>
      File(p.joinAll([tmp.path, ...relative.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  group('detectInstallation', () {
    test('dart pub global activate, from pub.dev', () {
      touch('pub-cache/global_packages/omnyshell/pubspec.lock', _hostedLock);
      final snapshot = touch(
        'pub-cache/global_packages/omnyshell/bin/omnyshell.dart-3.13.5.snapshot',
      );
      final found = detectInstallation(
        script: Uri.file(snapshot.path),
        resolvedExecutable: '/usr/lib/dart/bin/dart',
      )!;
      expect(found.method, InstallMethod.pubGlobal);
      expect(found.source, isA<HostedSource>());
      expect((found.source as HostedSource).isDefault, isTrue);
      expect(found.version, '1.63.3');
      expect(
        found.root,
        p.join(tmp.path, 'pub-cache', 'global_packages', 'omnyshell'),
      );
    });

    test('dart pub global activate, from git', () {
      touch('pub-cache/global_packages/omnyshell/pubspec.lock', _gitLock);
      final snapshot = touch(
        'pub-cache/global_packages/omnyshell/bin/omnyshell.dart-3.13.5.snapshot',
      );
      final found = detectInstallation(
        script: Uri.file(snapshot.path),
        resolvedExecutable: '/usr/lib/dart/bin/dart',
      )!;
      final source = found.source as GitSource;
      expect(source.url, 'https://github.com/OmnyGrid/omnyshell.git');
      expect(source.ref, 'main');
      expect(source.path, 'packages/omnyshell');
      expect(found.canTargetVersion, isFalse);
    });

    test('dart install, through its bin symlink', () {
      const bundle = 'install/app-bundles/omnyshell/hosted/1.63.3';
      touch('$bundle/pubspec.lock', _hostedLock);
      final exe = touch('$bundle/bundle/bin/omnyshell');
      final link = Link(p.join(tmp.path, 'install', 'bin', 'omnyshell'))
        ..createSync(exe.path, recursive: true);
      final found = detectInstallation(
        script: Uri.file(link.path),
        resolvedExecutable: link.path,
      )!;
      expect(found.method, InstallMethod.dartInstall);
      expect(found.version, '1.63.3');
      // Resolved: macOS's temp dir is under the /var → /private/var link.
      expect(
        Directory(found.root).resolveSymbolicLinksSync(),
        Directory(
          p.joinAll([tmp.path, ...bundle.split('/')]),
        ).resolveSymbolicLinksSync(),
      );
    }, skip: Platform.isWindows ? 'symlinks need privileges' : null);

    test('dart pub global activate --source path, run from the checkout', () {
      final checkout = Directory(p.join(tmp.path, 'src', 'omnyshell'))
        ..createSync(recursive: true);
      final cache = p.join(tmp.path, 'pub-cache');
      touch(
        'pub-cache/global_packages/omnyshell/pubspec.lock',
        _pathLock(checkout.path),
      );
      final script = touch('src/omnyshell/bin/omnyshell.dart');
      final found = detectInstallation(
        script: Uri.file(script.path),
        resolvedExecutable: '/usr/lib/dart/bin/dart',
        pubCache: cache,
      )!;
      expect(found.method, InstallMethod.pubGlobal);
      expect(found.source, isA<PathSource>());
      expect(found.version, '1.64.0-dev');
    });

    test(
      'path activation through a symlinked checkout path is still found',
      () {
        final real = Directory(p.join(tmp.path, 'real', 'omnyshell'))
          ..createSync(recursive: true);
        final link = Link(p.join(tmp.path, 'workspace'))
          ..createSync(p.join(tmp.path, 'real'));
        // Activated through the link, run through the real path.
        touch(
          'pub-cache/global_packages/omnyshell/pubspec.lock',
          _pathLock(p.join(link.path, 'omnyshell')),
        );
        final script = touch('real/omnyshell/bin/omnyshell.dart');
        final found = detectInstallation(
          script: Uri.file(script.path),
          resolvedExecutable: '/usr/lib/dart/bin/dart',
          pubCache: p.join(tmp.path, 'pub-cache'),
        );
        expect(found?.source, isA<PathSource>());
        expect(real.existsSync(), isTrue);
      },
      skip: Platform.isWindows ? 'symlinks need privileges' : null,
    );

    test('a checkout run with dart run is no installation', () {
      final checkout = Directory(p.join(tmp.path, 'src', 'omnyshell'))
        ..createSync(recursive: true);
      touch(
        'pub-cache/global_packages/omnyshell/pubspec.lock',
        _pathLock(p.join(tmp.path, 'another-checkout')),
      );
      final script = touch('src/omnyshell/bin/omnyshell.dart');
      expect(
        detectInstallation(
          script: Uri.file(script.path),
          resolvedExecutable: '/usr/lib/dart/bin/dart',
          pubCache: p.join(tmp.path, 'pub-cache'),
        ),
        isNull,
      );
      expect(checkout.existsSync(), isTrue);
    });

    test('an installation without a lock file is not trusted', () {
      final snapshot = touch(
        'pub-cache/global_packages/omnyshell/bin/omnyshell.dart-3.13.5.snapshot',
      );
      expect(
        detectInstallation(
          script: Uri.file(snapshot.path),
          resolvedExecutable: '/usr/lib/dart/bin/dart',
          pubCache: p.join(tmp.path, 'empty-cache'),
        ),
        isNull,
      );
    });
  });

  group('parseLockSource', () {
    test('git, with ref and path', () {
      final source =
          parseLockSource({
                'source': 'git',
                'description': {
                  'url': 'https://example.com/r.git',
                  'ref': 'v2',
                  'path': 'pkg',
                },
              })
              as GitSource;
      expect(source.url, 'https://example.com/r.git');
      expect(source.ref, 'v2');
      expect(source.path, 'pkg');
    });

    test('an unknown source is not reinstallable', () {
      expect(parseLockSource({'source': 'sdk'}), isNull);
    });
  });

  group('updateCommand', () {
    Installation install(InstallMethod method, PackageSource source) =>
        Installation(
          package: 'omnyshell',
          method: method,
          source: source,
          version: '1.63.3',
          root: tmp.path,
        );

    const pubDev = HostedSource('https://pub.dev');
    const private = HostedSource('https://pub.example.com');
    const git = GitSource(
      'https://github.com/OmnyGrid/omnyshell.git',
      ref: 'main',
      path: 'pkg',
    );
    const path = PathSource('/src/omnyshell');

    test('pub global, pub.dev: latest, or a version', () {
      final i = install(InstallMethod.pubGlobal, pubDev);
      expect(i.updateCommand(dart: 'dart'), [
        'dart',
        'pub',
        'global',
        'activate',
        'omnyshell',
      ]);
      expect(i.updateCommand(dart: 'dart', version: '1.64.0').last, '1.64.0');
    });

    test('pub global, another repository', () {
      expect(
        install(InstallMethod.pubGlobal, private).updateCommand(dart: 'dart'),
        [
          'dart',
          'pub',
          'global',
          'activate',
          'omnyshell',
          '--hosted-url',
          'https://pub.example.com',
        ],
      );
    });

    test('pub global, git and path', () {
      expect(
        install(InstallMethod.pubGlobal, git).updateCommand(dart: 'dart'),
        [
          'dart',
          'pub',
          'global',
          'activate',
          '--source',
          'git',
          'https://github.com/OmnyGrid/omnyshell.git',
          '--git-ref',
          'main',
          '--git-path',
          'pkg',
        ],
      );
      expect(
        install(InstallMethod.pubGlobal, path).updateCommand(dart: 'dart'),
        [
          'dart',
          'pub',
          'global',
          'activate',
          '--source',
          'path',
          '/src/omnyshell',
        ],
      );
    });

    test('dart install, each source', () {
      String descriptor(PackageSource s, [String? v]) => install(
        InstallMethod.dartInstall,
        s,
      ).updateCommand(dart: 'dart', version: v).last;

      expect(descriptor(pubDev), 'omnyshell');
      expect(descriptor(pubDev, '1.64.0'), 'omnyshell@1.64.0');
      // URLs and paths are quoted; simple words and versions are not.
      expect(
        descriptor(private, '1.64.0'),
        "omnyshell@{hosted: 'https://pub.example.com', version: 1.64.0}",
      );
      expect(
        descriptor(git),
        "omnyshell@{git: {url: 'https://github.com/OmnyGrid/omnyshell.git', "
        'ref: main, path: pkg}}',
      );
      expect(descriptor(path), "omnyshell@{path: '/src/omnyshell'}");
      // A constraint's leading `>` would start a YAML block scalar.
      expect(
        descriptor(private, '>=1.60.0'),
        "omnyshell@{hosted: 'https://pub.example.com', version: '>=1.60.0'}",
      );
      expect(descriptor(pubDev, '>=1.60.0'), "omnyshell@'>=1.60.0'");
      expect(
        install(
          InstallMethod.dartInstall,
          pubDev,
        ).updateCommand(dart: 'dart').take(2),
        ['dart', 'install'],
      );
    });

    test('a version cannot be chosen for git or path sources', () {
      final i = install(InstallMethod.pubGlobal, git);
      expect(i.canTargetVersion, isFalse);
      expect(
        () => i.updateCommand(dart: 'dart', version: '1.0.0'),
        throwsArgumentError,
      );
    });

    test('quotes descriptor values YAML would misread', () {
      expect(
        install(
          InstallMethod.dartInstall,
          const PathSource("/home/o'brien/my tools"),
        ).updateCommand(dart: 'dart').last,
        "omnyshell@{path: '/home/o''brien/my tools'}",
      );
    });
  });

  group('sudoMisuse', () {
    Installation at(String root) => Installation(
      package: 'omnyshell',
      method: InstallMethod.pubGlobal,
      source: const HostedSource('https://pub.dev'),
      version: '1.0.0',
      root: root,
    );

    test('refuses sudo on another user\'s installation', () {
      final reason = sudoMisuse(
        at('/home/alice/.pub-cache/global_packages/omnyshell'),
        environment: {'SUDO_USER': 'alice'},
        operatingSystem: 'linux',
      );
      expect(reason, contains('without sudo'));
      expect(reason, contains('alice'));
    });

    test('allows root\'s own installation, and no sudo at all', () {
      expect(
        sudoMisuse(
          at('/root/.pub-cache/global_packages/omnyshell'),
          environment: {'SUDO_USER': 'alice'},
          operatingSystem: 'linux',
        ),
        isNull,
      );
      expect(
        sudoMisuse(
          at('/var/root/.pub-cache/global_packages/omnyshell'),
          environment: {'SUDO_USER': 'alice'},
          operatingSystem: 'macos',
        ),
        isNull,
      );
      // macOS: a `dart install` root is symlink-resolved to /private/var.
      expect(
        sudoMisuse(
          at(
            '/private/var/root/Library/Application Support/Dart/install/'
            'app-bundles/omnyshell/hosted/1.64.0',
          ),
          environment: {'SUDO_USER': 'alice'},
          operatingSystem: 'macos',
        ),
        isNull,
      );
      expect(
        sudoMisuse(
          at('/home/alice/.pub-cache/global_packages/omnyshell'),
          environment: const {},
          operatingSystem: 'linux',
        ),
        isNull,
      );
    });

    test('does not apply on Windows', () {
      expect(
        sudoMisuse(
          at(r'C:\Users\alice\AppData\Local\Pub\Cache'),
          environment: {'SUDO_USER': 'alice'},
          operatingSystem: 'windows',
        ),
        isNull,
      );
    });
  });

  group('directLauncher', () {
    test('pub global: the Dart VM and the newest snapshot', () async {
      final root = p.join(tmp.path, 'global_packages', 'omnyshell');
      touch('global_packages/omnyshell/bin/omnyshell.dart-3.12.0.snapshot');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final newer = touch(
        'global_packages/omnyshell/bin/omnyshell.dart-3.13.5.snapshot',
      );
      final i = Installation(
        package: 'omnyshell',
        method: InstallMethod.pubGlobal,
        source: const HostedSource('https://pub.dev'),
        version: '1.63.3',
        root: root,
      );
      expect(i.directLauncher(dart: '/sdk/dart'), ['/sdk/dart', newer.path]);
    });

    test('dart install: the version asked for, over a newer folder', () async {
      final exe = Platform.isWindows ? 'omnyshell.exe' : 'omnyshell';
      final wanted = touch(
        'app-bundles/omnyshell/hosted/1.63.4/bundle/bin/$exe',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      touch('app-bundles/omnyshell/hosted/1.64.0/bundle/bin/$exe');
      final i = Installation(
        package: 'omnyshell',
        method: InstallMethod.dartInstall,
        source: const HostedSource('https://pub.dev'),
        version: '1.64.0',
        root: p.join(tmp.path, 'app-bundles', 'omnyshell', 'hosted', '1.64.0'),
      );
      // `update --to 1.63.4`: the 1.63.4 binary, though 1.64.0 is newer.
      expect(i.directLauncher(dart: 'dart', version: '1.63.4'), [wanted.path]);
    });

    test('dart install: the newest version\'s binary beside the old', () async {
      final exe = Platform.isWindows ? 'omnyshell.exe' : 'omnyshell';
      touch('app-bundles/omnyshell/hosted/1.63.3/bundle/bin/$exe');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final newer = touch(
        'app-bundles/omnyshell/hosted/1.64.0/bundle/bin/$exe',
      );
      final i = Installation(
        package: 'omnyshell',
        method: InstallMethod.dartInstall,
        source: const HostedSource('https://pub.dev'),
        version: '1.63.3',
        root: p.join(tmp.path, 'app-bundles', 'omnyshell', 'hosted', '1.63.3'),
      );
      expect(i.directLauncher(dart: 'dart'), [newer.path]);
    });

    test('pub global from a path: the checkout\'s entry point', () {
      final script = touch('src/omnyshell/bin/omnyshell.dart');
      final i = Installation(
        package: 'omnyshell',
        method: InstallMethod.pubGlobal,
        source: PathSource(p.join(tmp.path, 'src', 'omnyshell')),
        version: '1.64.0-dev',
        root: tmp.path,
      );
      expect(i.directLauncher(dart: 'dart'), ['dart', script.path]);
    });
  });
}
