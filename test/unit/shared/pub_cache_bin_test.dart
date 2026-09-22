@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/src/shared/utils/pub_cache_bin.dart';
import 'package:test/test.dart';

void main() {
  /// A throwaway directory tree, deleted when the test ends.
  Directory tempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  group('pubCacheBinDir', () {
    test('resolves \$PUB_CACHE/bin when the cache says where it is', () {
      final cache = tempDir('omnyshell-pub-cache-');
      final bin = Directory('${cache.path}/bin')..createSync();

      expect(pubCacheBinDir(environment: {'PUB_CACHE': cache.path}), bin.path);
    });

    test('ignores a trailing separator on \$PUB_CACHE', () {
      final cache = tempDir('omnyshell-pub-cache-');
      final bin = Directory('${cache.path}/bin')..createSync();

      expect(
        pubCacheBinDir(environment: {'PUB_CACHE': '${cache.path}/'}),
        bin.path,
      );
    });

    test('stays silent when the cache has no bin directory', () {
      final cache = tempDir('omnyshell-pub-cache-');

      expect(pubCacheBinDir(environment: {'PUB_CACHE': cache.path}), isNull);
    });

    test('falls back to ~/.pub-cache/bin', () {
      final home = tempDir('omnyshell-home-');
      final bin = Directory('${home.path}/.pub-cache/bin')
        ..createSync(recursive: true);

      expect(pubCacheBinDir(environment: {'HOME': home.path}), bin.path);
    }, skip: Platform.isWindows ? 'POSIX cache layout' : null);

    test('stays silent when there is no cache at all', () {
      final home = tempDir('omnyshell-home-');

      expect(
        pubCacheBinDir(
          environment: {
            'HOME': home.path,
            'USERPROFILE': home.path,
            'LOCALAPPDATA': home.path,
            'APPDATA': home.path,
          },
        ),
        isNull,
      );
    });
  });

  group('withPubCacheBin', () {
    /// A pub cache whose `bin` exists, as the environment naming it.
    (String, Map<String, String>) cacheEnv() {
      final cache = tempDir('omnyshell-pub-cache-');
      final bin = Directory('${cache.path}/bin')..createSync();
      return (bin.path, {'PUB_CACHE': cache.path});
    }

    test('appends the bin directory to the PATH the session carries', () {
      final (bin, parent) = cacheEnv();

      final env = withPubCacheBin({
        'PATH': '/usr/bin:/bin',
      }, processEnvironment: parent);

      expect(env['PATH'], '/usr/bin:/bin:$bin');
    });

    test('appends, so the operator PATH keeps precedence', () {
      final (bin, parent) = cacheEnv();

      final env = withPubCacheBin({
        'PATH': '/opt/homebrew/bin',
      }, processEnvironment: parent);

      expect(env['PATH']!.split(':').last, bin);
    });

    test('builds on the inherited PATH when the session carries none', () {
      final (bin, parent) = cacheEnv();

      final env = withPubCacheBin(
        {'TERM': 'xterm'},
        processEnvironment: {...parent, 'PATH': '/usr/bin'},
      );

      expect(env['PATH'], '/usr/bin:$bin');
      expect(env['TERM'], 'xterm', reason: 'the rest is passed through');
    });

    test('leaves a PATH that already has the directory alone', () {
      final (bin, parent) = cacheEnv();

      final env = withPubCacheBin({
        'PATH': '$bin:/usr/bin',
      }, processEnvironment: parent);

      expect(env['PATH'], '$bin:/usr/bin');
    });

    test('recognises the directory written with a trailing separator', () {
      final (bin, parent) = cacheEnv();

      final env = withPubCacheBin({
        'PATH': '/usr/bin:$bin/',
      }, processEnvironment: parent);

      expect(env['PATH'], '/usr/bin:$bin/');
    });

    test('adds nothing when there is no pub cache to point at', () {
      final home = tempDir('omnyshell-home-');

      final env = withPubCacheBin(
        {'PATH': '/usr/bin'},
        processEnvironment: {
          'HOME': home.path,
          'USERPROFILE': home.path,
          'LOCALAPPDATA': home.path,
          'APPDATA': home.path,
        },
      );

      expect(env['PATH'], '/usr/bin');
    });

    test('honours a PUB_CACHE the session itself sets', () {
      final cache = tempDir('omnyshell-pub-cache-');
      final bin = Directory('${cache.path}/bin')..createSync();
      final (otherBin, parent) = cacheEnv();

      final env = withPubCacheBin({
        'PATH': '/usr/bin',
        'PUB_CACHE': cache.path,
      }, processEnvironment: parent);

      expect(env['PATH'], '/usr/bin:${bin.path}');
      expect(env['PATH'], isNot(contains(otherBin)));
    });

    test('sets PATH from nothing when neither side has one', () {
      final (bin, parent) = cacheEnv();

      final env = withPubCacheBin(const {}, processEnvironment: parent);

      expect(env['PATH'], bin);
    });
  }, skip: Platform.isWindows ? 'POSIX PATH separator' : null);
}
