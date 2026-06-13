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

  group('remoteCompletionCommand delegates to PosixShellDialect', () {
    test('matches the posix dialect for command and argument positions', () {
      for (final isCommand in [true, false]) {
        expect(
          remoteCompletionCommand('al', isCommand: isCommand),
          const PosixShellDialect().completionCommand(
            'al',
            isCommand: isCommand,
          ),
        );
      }
    });
  });

  group('PowerShellDialect.completionCommand', () {
    const dialect = PowerShellDialect();

    test('argument position globs files via Get-ChildItem', () {
      final cmd = dialect.completionCommand('fil', isCommand: false);
      expect(cmd, startsWith(r"$w='fil';"));
      expect(cmd, contains('Get-ChildItem'));
      expect(cmd, isNot(contains('Get-Command')));
    });

    test('command position scans commands via Get-Command', () {
      final cmd = dialect.completionCommand('ls', isCommand: true);
      expect(cmd, contains('Get-Command'));
      expect(cmd, contains(r"($w+'*')"));
    });

    test('a command-position word with a separator is treated as a path', () {
      for (final w in [r'.\fi', './fi']) {
        final cmd = dialect.completionCommand(w, isCommand: true);
        expect(cmd, contains('Get-ChildItem'));
        expect(cmd, isNot(contains('Get-Command')));
      }
    });

    test('embeds the word as a single-quoted literal, doubling quotes', () {
      expect(
        dialect.completionCommand("a'b", isCommand: false),
        startsWith(r"$w='a''b';"),
      );
    });
  });

  group('CmdShellDialect.completionCommand', () {
    const dialect = CmdShellDialect();

    test('argument position lists dirs (suffixed /) then files', () {
      final cmd = dialect.completionCommand('fil', isCommand: false);
      expect(cmd, contains('for /d %A in (fil*)'));
      expect(cmd, contains('echo %A/'));
    });

    test('command position scans %PATH% via where', () {
      final cmd = dialect.completionCommand('ls', isCommand: true);
      expect(cmd, contains('where "ls*"'));
    });

    test('a command-position word with a separator is treated as a path', () {
      final cmd = dialect.completionCommand(r'sub\fi', isCommand: true);
      expect(cmd, contains('for /d %A in'));
      expect(cmd, isNot(contains('where')));
    });
  });

  group('PowerShellDialect.completionCommand (executed in pwsh)', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('compl_ps_test');
      File('${dir.path}/alpha.txt').writeAsStringSync('');
      File('${dir.path}/album.md').writeAsStringSync('');
      Directory('${dir.path}/sub').createSync();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('completes files and marks directories with a trailing slash', () {
      final pwsh = _findPwsh();
      if (pwsh == null) {
        markTestSkipped('PowerShell (pwsh/powershell) not available');
        return;
      }
      final files = _runPwsh(
        pwsh,
        const PowerShellDialect().completionCommand('al', isCommand: false),
        dir,
      )..sort();
      expect(files, ['album.md', 'alpha.txt']);

      final dirs = _runPwsh(
        pwsh,
        const PowerShellDialect().completionCommand('su', isCommand: false),
        dir,
      );
      expect(dirs, ['sub/']);
    });
  });
}

/// Resolves a PowerShell executable for the guarded execution test, or `null`.
String? _findPwsh() {
  for (final exe in const ['pwsh', 'powershell']) {
    try {
      if (Process.runSync(exe, const [
            '-NoProfile',
            '-Command',
            'exit 0',
          ]).exitCode ==
          0) {
        return exe;
      }
    } on Object {
      // Not present; try the next candidate.
    }
  }
  return null;
}

/// Runs [command] in [dir] via [pwsh] and returns the non-empty output lines.
List<String> _runPwsh(String pwsh, String command, Directory dir) {
  final result = Process.runSync(pwsh, [
    '-NoLogo',
    '-NoProfile',
    '-Command',
    command,
  ], workingDirectory: dir.path);
  return (result.stdout as String)
      .split('\n')
      .map((s) => s.trimRight())
      .where((s) => s.isNotEmpty)
      .toList();
}
