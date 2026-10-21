import 'dart:convert';

import 'package:omnyshell/src/application/client/ide/ide_command_support.dart';
import 'package:omnyshell/src/application/client/ide/workspace/remote_workspace.dart';
import 'package:test/test.dart';

/// The `:ide` workspace's Windows support that needs no Windows: remote path
/// handling, and the shape of the PowerShell scripts a Windows node runs
/// (those run for real in `test/integration/ide_remote_workspace_test`).
void main() {
  group('resolveRemoteIdeRoot on a Windows node', () {
    test('the working directory, with `/` separators', () {
      expect(resolveRemoteIdeRoot(null, r'C:\Users\u'), 'C:/Users/u');
      expect(resolveRemoteIdeRoot('.', r'C:\Users\u'), 'C:/Users/u');
    });

    test('a relative path joins the working directory', () {
      expect(
        resolveRemoteIdeRoot(r'src\app', r'C:\Users\u'),
        'C:/Users/u/src/app',
      );
      expect(resolveRemoteIdeRoot('..', r'C:\Users\u'), 'C:/Users');
    });

    test('an absolute Windows path is used as it is', () {
      expect(resolveRemoteIdeRoot(r'D:\proj', r'C:\Users\u'), 'D:/proj');
      expect(resolveRemoteIdeRoot('D:/proj/', null), 'D:/proj');
      expect(
        resolveRemoteIdeRoot(r'\\server\share\x', r'C:\'),
        '//server/share/x',
      );
    });

    test('a drive root keeps its slash (a bare `C:` means its cwd)', () {
      expect(resolveRemoteIdeRoot(r'C:\', null), 'C:/');
      expect(resolveRemoteIdeRoot('..', r'C:\Users'), 'C:/');
    });

    test('a POSIX node is unchanged', () {
      expect(resolveRemoteIdeRoot(null, '/home/u'), '/home/u');
      expect(resolveRemoteIdeRoot('src', '/home/u'), '/home/u/src');
      expect(resolveRemoteIdeRoot('/srv/app/', '/home/u'), '/srv/app');
      expect(resolveRemoteIdeRoot('src', null), isNull);
    });
  });

  test('normalizeRemotePath only touches Windows paths', () {
    expect(normalizeRemotePath(r'C:\a\b'), 'C:/a/b');
    expect(normalizeRemotePath(r'\\srv\s'), '//srv/s');
    expect(normalizeRemotePath(r'/home/u/odd\name'), r'/home/u/odd\name');
    expect(isWindowsRemotePath('C:'), isTrue);
    expect(isWindowsRemotePath('/c/Users'), isFalse);
  });

  group('the PowerShell scripts', () {
    const path = "C:/Users/u/it's here.txt";
    final scripts = [
      windowsListScript(path),
      windowsReadScript(path),
      windowsCreateFileScript(path),
      ...windowsWriteScripts(path, base64.encode(utf8.encode('x'))),
    ];

    test('quote the path for PowerShell', () {
      for (final s in scripts) {
        expect(s, contains("'C:/Users/u/it''s here.txt'"));
      }
    });

    test('hold no double quotes (they reach powershell.exe through the '
        'Windows command line)', () {
      for (final s in scripts) {
        expect(s, isNot(contains('"')), reason: s);
      }
    });

    test('fail with exit 1 and the message on stderr', () {
      for (final s in scripts) {
        expect(s, startsWith("try { \$ErrorActionPreference = 'Stop'; "));
        expect(s, endsWith('exit 1 }'));
      }
    });
  });

  group('windowsWriteScripts', () {
    test('one script creates, the rest append, in order', () {
      final b64 = 'A' * 40000; // 3 chunks of at most 16000
      final scripts = windowsWriteScripts('C:/f', b64);
      expect(scripts, hasLength(3));
      expect(scripts[0], contains('[IO.FileMode]::Create'));
      expect(scripts[1], contains('[IO.FileMode]::Append'));
      expect(scripts[2], contains('[IO.FileMode]::Append'));
      final carried = scripts
          .map((s) => RegExp(r"FromBase64String\('([^']*)'\)").firstMatch(s)!)
          .map((m) => m.group(1)!)
          .join();
      expect(carried, b64);
    });

    test('each script stays far under the 32,767-character command line', () {
      final b64 = base64.encode(List.filled(200000, 7));
      for (final s in windowsWriteScripts('C:/Users/u/f.txt', b64)) {
        expect(s.length, lessThan(20000));
      }
    });

    test('empty content still creates (truncates) the file', () {
      final scripts = windowsWriteScripts('C:/f', '');
      expect(scripts, hasLength(1));
      expect(scripts.single, contains('[IO.FileMode]::Create'));
      expect(scripts.single, contains("FromBase64String('')"));
    });

    test('chunks never split a base64 quantum', () {
      expect(
        () => windowsWriteScripts('C:/f', 'AAAA', chunk: 6),
        throwsA(anything),
      );
    });
  });
}
