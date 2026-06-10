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
}
