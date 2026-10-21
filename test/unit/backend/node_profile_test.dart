import 'dart:io';

import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

void main() {
  group('NodeProfile.load', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omnyshell-profile-test');
      path = '${dir.path}${Platform.pathSeparator}profile.yaml';
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('missing file yields an empty profile', () {
      expect(NodeProfile.load(path: path).env, isEmpty);
    });

    test('empty file yields an empty profile', () {
      File(path).writeAsStringSync('   \n');
      expect(NodeProfile.load(path: path).env, isEmpty);
    });

    test('parses env and coerces non-string values to strings', () {
      File(path).writeAsStringSync('''
env:
  PATH: "/usr/local/bin:/usr/bin"
  EDITOR: vim
  PORT: 8080
  DEBUG: true
''');
      final env = NodeProfile.load(path: path).env;
      expect(env['PATH'], '/usr/local/bin:/usr/bin');
      expect(env['EDITOR'], 'vim');
      expect(env['PORT'], '8080');
      expect(env['DEBUG'], 'true');
    });

    test('expands \${VAR} and \$VAR against the environment', () {
      File(path).writeAsStringSync('''
env:
  PATH: "/opt/bin:\${PATH}"
  HOMEISH: \$HOME/x
''');
      final env = NodeProfile.load(
        path: path,
        environment: {'PATH': '/usr/bin', 'HOME': '/home/me'},
      ).env;
      expect(env['PATH'], '/opt/bin:/usr/bin');
      expect(env['HOMEISH'], '/home/me/x');
    });

    test('unknown variables expand to empty', () {
      File(path).writeAsStringSync('env:\n  X: "a\${NOPE}b"\n');
      final env = NodeProfile.load(path: path, environment: {}).env;
      expect(env['X'], 'ab');
    });

    test('no env key yields an empty profile', () {
      File(path).writeAsStringSync('other: 1\n');
      expect(NodeProfile.load(path: path).env, isEmpty);
    });

    test('non-mapping env throws FormatException', () {
      File(path).writeAsStringSync('env: [a, b]\n');
      expect(() => NodeProfile.load(path: path), throwsFormatException);
    });

    test('invalid YAML throws FormatException', () {
      File(path).writeAsStringSync('env: : :\n  - broken\n');
      expect(() => NodeProfile.load(path: path), throwsFormatException);
    });
  });

  group('NodeProfile.writePath', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omnyshell-profile-write');
      path = '${dir.path}${Platform.pathSeparator}profile.yaml';
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('creates the file when absent', () {
      NodeProfile.writePath(path, '/opt/bin:/usr/bin');
      expect(File(path).existsSync(), isTrue);
      expect(NodeProfile.load(path: path).env['PATH'], '/opt/bin:/usr/bin');
    });

    test('creates parent directories when absent', () {
      final nested = '${dir.path}/a/b/profile.yaml';
      NodeProfile.writePath(nested, '/x');
      expect(NodeProfile.load(path: nested).env['PATH'], '/x');
    });

    test('updates PATH while preserving other env keys and comments', () {
      File(path).writeAsStringSync('''
# my node profile
env:
  FOO: bar
  PATH: "/old/bin"
''');
      NodeProfile.writePath(path, '/new/bin:/usr/bin');

      final env = NodeProfile.load(path: path).env;
      expect(env['PATH'], '/new/bin:/usr/bin');
      expect(env['FOO'], 'bar');
      expect(File(path).readAsStringSync(), contains('# my node profile'));
    });

    test('adds env.PATH when env exists without it', () {
      File(path).writeAsStringSync('env:\n  FOO: bar\n');
      NodeProfile.writePath(path, '/p');
      final env = NodeProfile.load(path: path).env;
      expect(env['PATH'], '/p');
      expect(env['FOO'], 'bar');
    });
  });

  group('pathDiff', () {
    test('null old path counts as changed and all-added', () {
      final d = pathDiff(null, '/a:/b');
      expect(d.changed, isTrue);
      expect(d.added, ['/a', '/b']);
      expect(d.removed, isEmpty);
    });

    test('equal paths are unchanged', () {
      final d = pathDiff('/a:/b', '/a:/b');
      expect(d.changed, isFalse);
      expect(d.added, isEmpty);
      expect(d.removed, isEmpty);
    });

    test('reports added and removed entries', () {
      final d = pathDiff('/a:/b', '/a:/c');
      expect(d.changed, isTrue);
      expect(d.added, ['/c']);
      expect(d.removed, ['/b']);
    });
  });

  group('uniquePath', () {
    test('removes duplicate entries preserving first occurrence', () {
      expect(uniquePath('/a:/b:/a:/c:/b'), '/a:/b:/c');
    });

    test('drops empty segments', () {
      expect(uniquePath('/a::/b:'), '/a:/b');
    });

    test('leaves an already-unique path untouched', () {
      expect(uniquePath('/a:/b:/c'), '/a:/b:/c');
    });

    test('empty string yields empty string', () {
      expect(uniquePath(''), '');
    });
  });

  group('rcFileFor', () {
    test('maps known shells to their rc file', () {
      expect(rcFileFor('/bin/zsh'), '~/.zshrc');
      expect(rcFileFor('/usr/bin/bash'), '~/.bashrc');
      expect(rcFileFor('/opt/fish'), '~/.config/fish/config.fish');
      expect(rcFileFor('/bin/dash'), '~/.profile');
    });
  });

  group('captureLoginPath', () {
    test('extracts PATH from the marked shell output', () async {
      if (Platform.isWindows) return; // POSIX-only path capture.
      final dir = Directory.systemTemp.createTempSync('omnyshell-fake-shell');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fakeShell = '${dir.path}/fakeshell';
      File(fakeShell).writeAsStringSync(
        '#!/bin/sh\nprintf "<<OMNYPATH>>/fake/bin:/usr/bin<<ENDPATH>>"\n',
      );
      Process.runSync('chmod', ['+x', fakeShell]);

      final path = await captureLoginPath(shell: fakeShell);
      expect(path, '/fake/bin:/usr/bin');
    });

    test('returns null when the shell cannot be started', () async {
      final path = await captureLoginPath(
        shell: '/nonexistent/shell-xyz',
        timeout: const Duration(seconds: 2),
      );
      expect(path, isNull);
    });
  });

  group('LiveNodeProfile', () {
    late Directory dir;
    late String path;
    late List<String> warnings;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omnyshell-live-profile');
      path = '${dir.path}${Platform.pathSeparator}profile.yaml';
      warnings = [];
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    LiveNodeProfile follow() =>
        LiveNodeProfile(path: path, onWarning: warnings.add);

    test('applies an edit to the next call', () {
      File(path).writeAsStringSync('env:\n  A: one\n');
      final profile = follow();
      expect(profile.envFor({}), {'A': 'one'});
      File(path).writeAsStringSync('env:\n  A: two\n  B: new\n');
      expect(profile.envFor({}), {'A': 'two', 'B': 'new'});
    });

    test('sees an edit that keeps the same size', () {
      // Same length and possibly the same mtime second: compared by content.
      File(path).writeAsStringSync('env:\n  A: aaa\n');
      final profile = follow();
      expect(profile.envFor({})['A'], 'aaa');
      File(path).writeAsStringSync('env:\n  A: bbb\n');
      expect(profile.envFor({})['A'], 'bbb');
    });

    test('a file created later applies; a deleted one empties it', () {
      final profile = follow();
      expect(profile.envFor({}), isEmpty);
      File(path).writeAsStringSync('env:\n  A: one\n');
      expect(profile.envFor({}), {'A': 'one'});
      File(path).deleteSync();
      expect(profile.envFor({}), isEmpty);
    });

    test('expands references against the environment of each call', () {
      File(path).writeAsStringSync(r'env: {PATH: "/opt/x:${PATH}"}');
      final profile = follow();
      expect(profile.envFor({'PATH': '/a'})['PATH'], '/opt/x:/a');
      // A PATH that changed since (e.g. on Windows, in the registry) is
      // followed rather than frozen at load time.
      expect(profile.envFor({'PATH': '/b'})['PATH'], '/opt/x:/b');
    });

    test('keeps the last good profile while an edit is broken', () {
      File(path).writeAsStringSync('env:\n  A: good\n');
      final profile = follow();
      expect(profile.envFor({}), {'A': 'good'});

      File(path).writeAsStringSync('env: [unclosed\n');
      expect(profile.envFor({}), {'A': 'good'});
      expect(profile.envFor({}), {'A': 'good'});
      // Warned once for that broken text, not on every session.
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('keeping the previous profile'));

      File(path).writeAsStringSync('env:\n  A: fixed\n');
      expect(profile.envFor({}), {'A': 'fixed'});
      expect(warnings, hasLength(1));
    });

    test('a broken profile at start still fails fast', () {
      File(path).writeAsStringSync('env: [unclosed\n');
      expect(follow, throwsFormatException);
    });
  });

  group('baseEnvironmentFor', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omnyshell-live-profile-be');
      path = '${dir.path}${Platform.pathSeparator}profile.yaml';
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<String> run(ShellBackend backend, String command) async {
      final session = await backend.start(
        ShellRequest(mode: SessionMode.exec, command: command),
      );
      final out = await session.stdout
          .expand((e) => e)
          .map(String.fromCharCode)
          .join();
      await session.exitCode;
      return out.trim();
    }

    test(
      'a new session sees a profile edited after the backend was created',
      () async {
        File(path).writeAsStringSync('env:\n  OMNY_LIVE: before\n');
        final profile = LiveNodeProfile(path: path);
        final backend = ProcessShellBackend(baseEnvironmentFor: profile.envFor);
        final echo = Platform.isWindows
            ? 'echo %OMNY_LIVE%'
            : r'echo "$OMNY_LIVE"';
        expect(await run(backend, echo), 'before');
        File(path).writeAsStringSync('env:\n  OMNY_LIVE: after\n');
        expect(await run(backend, echo), 'after');
      },
    );

    test('a profile HOME edited later becomes the start directory', () async {
      final home = Directory('${dir.path}${Platform.pathSeparator}home')
        ..createSync();
      // Recognised by a marker file rather than by path, which Windows may
      // print in its 8.3 short form.
      File(
        '${home.path}${Platform.pathSeparator}omny-home-marker.txt',
      ).writeAsStringSync('in-profile-home');
      final profile = LiveNodeProfile(path: path);
      final backend = ProcessShellBackend(baseEnvironmentFor: profile.envFor);
      final show = Platform.isWindows
          ? 'type omny-home-marker.txt 2>nul'
          : 'cat omny-home-marker.txt 2>/dev/null';
      expect(await run(backend, show), isNot('in-profile-home'));
      // A YAML double-quoted scalar, so Windows backslashes survive.
      final quoted = home.path.replaceAll(r'\', r'\\');
      File(path).writeAsStringSync('env:\n  HOME: "$quoted"\n');
      expect(await run(backend, show), 'in-profile-home');
    });
  }, tags: ['windows']);
}
