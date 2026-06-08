import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// Runs [command] with `sh -c` in [dir] and returns the candidate lines.
List<String> _run(String command, Directory dir) {
  final result = Process.runSync('sh', [
    '-c',
    command,
  ], workingDirectory: dir.path);
  return (result.stdout as String)
      .split('\n')
      .map((s) => s.trimRight())
      .where((s) => s.isNotEmpty)
      .toList();
}

void main() {
  group('remoteCompletionCommand', () {
    test('embeds the word as a single-quoted literal', () {
      final cmd = remoteCompletionCommand('foo', isCommand: false);
      expect(cmd, startsWith("w='foo';"));
      // A quote in the word is escaped, not left to break out.
      final tricky = remoteCompletionCommand("a'b", isCommand: false);
      expect(tricky, contains(r"'a'\''b'"));
    });

    test('command position scans PATH; argument position globs files', () {
      expect(
        remoteCompletionCommand('ls', isCommand: true),
        contains(r'$PATH'),
      );
      expect(
        remoteCompletionCommand('fil', isCommand: false),
        isNot(contains(r'$PATH')),
      );
    });
  });

  group('remoteCompletionCommand (executed in sh)', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('compl_test');
      File('${dir.path}/alpha.txt').writeAsStringSync('');
      File('${dir.path}/album.md').writeAsStringSync('');
      Directory('${dir.path}/sub').createSync();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('completes files, marking directories with a trailing slash', () {
      final cmd = remoteCompletionCommand('al', isCommand: false);
      expect(_run(cmd, dir)..sort(), ['album.md', 'alpha.txt']);

      final dirs = _run(remoteCompletionCommand('su', isCommand: false), dir);
      expect(dirs, ['sub/']);
    });

    test('no match yields no candidates', () {
      expect(
        _run(remoteCompletionCommand('zzz', isCommand: false), dir),
        isEmpty,
      );
    });

    test('handles a word containing a space', () {
      File('${dir.path}/a b.txt').writeAsStringSync('');
      final cmd = remoteCompletionCommand('a b', isCommand: false);
      expect(_run(cmd, dir), ['a b.txt']);
    });

    test('command position finds an executable on PATH (sh)', () {
      // `sh` itself lives on PATH; completing "sh" should include it.
      final candidates = _run(
        remoteCompletionCommand('sh', isCommand: true),
        dir,
      );
      expect(candidates, contains('sh'));
    });

    test('command position with a slash completes paths', () {
      final cmd = remoteCompletionCommand('./al', isCommand: true);
      expect(_run(cmd, dir)..sort(), ['./album.md', './alpha.txt']);
    });
  });
}
