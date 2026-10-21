import 'package:omnyshell/src/application/client/ide/git/git_repo.dart';
import 'package:omnyshell/src/application/client/ide/ide_command_support.dart';
import 'package:omnyshell/src/application/client/ide/model/file_tree.dart';
import 'package:omnyshell/src/application/client/ide/terminal/command_runner.dart';
import 'package:omnyshell/src/application/client/ide/workspace/remote_workspace.dart';
import 'package:omnyshell/src/application/client/ide/workspace/workspace.dart';
import 'package:omnyshell/src/domain/backend/shell_family.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The `:ide` workspace's Windows support that needs no Windows: remote path
/// handling under Windows rules on any client, and the shape of the
/// PowerShell scripts a Windows node runs (those run for real in
/// `test/integration/ide_remote_workspace_test`).
void main() {
  group('resolveRemoteIdeRoot on a Windows node', () {
    test('the working directory, in native form', () {
      expect(resolveRemoteIdeRoot(null, r'C:\Users\u'), r'C:\Users\u');
      expect(resolveRemoteIdeRoot('.', 'C:/Users/u/'), r'C:\Users\u');
    });

    test('a relative path joins the working directory', () {
      expect(
        resolveRemoteIdeRoot('src/app', r'C:\Users\u'),
        r'C:\Users\u\src\app',
      );
      expect(resolveRemoteIdeRoot('..', r'C:\Users\u'), r'C:\Users');
    });

    test('an absolute Windows path is used as it is', () {
      expect(resolveRemoteIdeRoot(r'D:\proj', r'C:\Users\u'), r'D:\proj');
      expect(resolveRemoteIdeRoot('D:/proj/', null), r'D:\proj');
    });

    test('a share keeps its `\\\\server\\share` root', () {
      expect(
        resolveRemoteIdeRoot(r'\\server\share\x', r'C:\'),
        r'\\server\share\x',
      );
      expect(
        resolveRemoteIdeRoot('//server/share/x', r'C:\'),
        r'\\server\share\x',
      );
    });

    test('`..` stops at a share or drive root', () {
      expect(
        resolveRemoteIdeRoot(r'\\server\share\..\..', null),
        r'\\server\share',
      );
      expect(resolveRemoteIdeRoot(r'..\..\..', r'C:\Users\u'), r'C:\');
    });

    test('a drive root keeps its slash (a bare `C:` means its cwd)', () {
      expect(resolveRemoteIdeRoot(r'C:\', null), r'C:\');
      expect(resolveRemoteIdeRoot('C:', r'D:\x'), r'C:\');
      expect(resolveRemoteIdeRoot('..', r'C:\Users'), r'C:\');
    });

    test('a path rooted on the current drive takes the cwd drive', () {
      expect(resolveRemoteIdeRoot(r'\proj', r'D:\x\y'), r'D:\proj');
      expect(resolveRemoteIdeRoot('/proj', r'D:\x'), r'D:\proj');
      expect(resolveRemoteIdeRoot(r'\proj', null), isNull);
    });

    test('the shell family decides when the cwd is unknown', () {
      expect(
        resolveRemoteIdeRoot(
          'C:/a/./b',
          null,
          shellFamily: ShellFamily.powershell,
        ),
        r'C:\a\b',
      );
      expect(
        resolveRemoteIdeRoot('/srv/app', null, shellFamily: ShellFamily.posix),
        '/srv/app',
      );
    });

    test('a known cwd outweighs the shell family (Git Bash on Windows)', () {
      expect(
        resolveRemoteIdeRoot(
          'src',
          '/c/Users/u',
          shellFamily: ShellFamily.powershell,
        ),
        '/c/Users/u/src',
      );
    });
  });

  group('resolveRemoteIdeRoot on a POSIX node', () {
    test('is unchanged', () {
      expect(resolveRemoteIdeRoot(null, '/home/u'), '/home/u');
      expect(resolveRemoteIdeRoot('src', '/home/u'), '/home/u/src');
      expect(resolveRemoteIdeRoot('/srv/app/', '/home/u'), '/srv/app');
      expect(resolveRemoteIdeRoot('src', null), isNull);
    });

    test('a `//` path is an ordinary absolute path, not a share', () {
      expect(resolveRemoteIdeRoot('//srv/app', '/home/u'), '/srv/app');
      expect(resolveRemoteIdeRoot('//srv/app/..', '/home/u'), '/srv');
      expect(resolveRemoteIdeRoot('//srv/app', null), '/srv/app');
    });

    test(r'a `\` in a POSIX name is part of the name', () {
      expect(resolveRemoteIdeRoot(r'odd\name', '/home/u'), r'/home/u/odd\name');
    });
  });

  group('normalizeRemotePath', () {
    test('a Windows path takes its native form', () {
      expect(normalizeRemotePath('C:/a/b/'), r'C:\a\b');
      expect(normalizeRemotePath(r'\\srv\s\x\..'), r'\\srv\s');
      expect(normalizeRemotePath('C:'), r'C:\');
      expect(normalizeRemotePath('//srv/s/x', windows: true), r'\\srv\s\x');
    });

    test('a POSIX path is normalized under POSIX rules', () {
      expect(normalizeRemotePath('/home/u/./x/'), '/home/u/x');
      expect(normalizeRemotePath(r'/home/u/odd\name'), r'/home/u/odd\name');
    });

    test('isWindowsRemotePath', () {
      expect(isWindowsRemotePath('C:'), isTrue);
      expect(isWindowsRemotePath('c:/x'), isTrue);
      expect(isWindowsRemotePath(r'\\srv\s'), isTrue);
      expect(isWindowsRemotePath('//srv/s'), isFalse);
      expect(isWindowsRemotePath('/c/Users'), isFalse);
      expect(isWindowsRemotePath('C'), isFalse);
    });

    test('idePathContext follows the root, not this client', () {
      expect(idePathContext(r'C:\x').style, p.Style.windows);
      expect(idePathContext(r'\\srv\s').style, p.Style.windows);
      expect(idePathContext('/home/u').style, p.Style.posix);
    });
  });

  group('resolveInWorkspace (the agent\'s and new entries\' paths)', () {
    test('a Windows root, from a macOS/Linux client too', () {
      const root = r'C:\Users\u\proj';
      // The form the workspace and git report, absolute: used as it is.
      expect(
        resolveInWorkspace(root, root, 'C:/Users/u/proj/src/a.dart'),
        r'C:\Users\u\proj\src\a.dart',
      );
      expect(
        resolveInWorkspace(root, root, r'src\a.dart'),
        r'C:\Users\u\proj\src\a.dart',
      );
      expect(
        resolveInWorkspace(root, r'C:\Users\u\proj\src', 'b/c.dart'),
        r'C:\Users\u\proj\src\b\c.dart',
      );
      // Windows ignores case.
      expect(resolveInWorkspace(root, root, r'c:\users\U\PROJ\x'), isNotNull);
      expect(resolveInWorkspace(root, root, '.'), root);
    });

    test('a Windows path outside the root is refused', () {
      const root = r'C:\Users\u\proj';
      expect(resolveInWorkspace(root, root, r'..\other'), isNull);
      expect(resolveInWorkspace(root, root, r'D:\proj\x'), isNull);
      expect(resolveInWorkspace(root, root, r'\Windows'), isNull);
    });

    test('a share root', () {
      const root = r'\\srv\share\x';
      expect(
        resolveInWorkspace(root, root, '//srv/share/x/new.txt'),
        r'\\srv\share\x\new.txt',
      );
      expect(resolveInWorkspace(root, root, r'..\y'), isNull);
    });

    test('a POSIX root', () {
      expect(resolveInWorkspace('/p', '/p', 'a/../b'), '/p/b');
      expect(resolveInWorkspace('/p', '/p/s', 'x'), '/p/s/x');
      expect(resolveInWorkspace('/p', '/p', '../q'), isNull);
      expect(resolveInWorkspace('/p', '/p', '/etc/passwd'), isNull);
      // POSIX names are case-sensitive.
      expect(resolveInWorkspace('/p', '/p', '/P/x'), isNull);
    });
  });

  group('FileTree on a Windows root (any client)', () {
    Future<List<DirEntry>> lister(String path) async => switch (path) {
      r'\\srv\share\x' || r'C:\' => const [
        DirEntry('src', isDir: true),
        DirEntry('a.txt', isDir: false),
      ],
      r'\\srv\share\x\src' ||
      r'C:\src' => const [DirEntry('m.dart', isDir: false)],
      _ => throw StateError('unexpected list of $path'),
    };

    test('keeps a share root and lists under it', () async {
      final tree = FileTree(r'\\srv\share\x', lister: lister);
      await tree.init();
      expect(tree.root.path, r'\\srv\share\x');
      expect(tree.root.name, 'x');
      expect(tree.root.children!.map((c) => c.path), [
        r'\\srv\share\x\src',
        r'\\srv\share\x\a.txt',
      ]);
      final found = await tree.reveal('//srv/share/x/src/m.dart');
      expect(found?.path, r'\\srv\share\x\src\m.dart');
    });

    test('keeps a drive root (named after itself)', () async {
      final tree = FileTree('C:/', lister: lister);
      await tree.init();
      expect(tree.root.path, r'C:\');
      expect(tree.root.name, r'C:\');
      expect((await tree.reveal(r'c:\SRC\m.dart'))?.name, 'm.dart');
      expect(tree.findByPath('C:/src'), isNotNull);
      expect(await tree.reveal(r'D:\src'), isNull);
    });
  });

  group('GitRepo on a Windows root', () {
    test('holds git\'s `/` root in native form', () async {
      final ws = _Ws(r'\\srv\share\x', {
        'git rev-parse --show-toplevel': '//srv/share/x\n',
        'git status --porcelain': ' M src/m.dart\n',
        "git diff -U0 --no-color -- 'src/m.dart'": '',
      });
      final repo = (await GitRepo.discover(ws, ws.rootPath))!;
      expect(repo.root, r'\\srv\share\x');
      await repo.lineGutter(r'\\srv\share\x\src\m.dart');
      expect(ws.commands.last, "git diff -U0 --no-color -- 'src/m.dart'");
    });
  });

  group('the PowerShell scripts', () {
    const path = "C:/Users/u/it's here.txt";
    final scripts = {
      'list': windowsListScript(path),
      'read': windowsReadScript(path),
      'write': windowsWriteScript(path),
      'create file': windowsCreateFileScript(path),
      'create directory': windowsCreateDirectoryScript(path),
      'exists': windowsTestPathScript(path),
      'is directory': windowsTestPathScript(path, directory: true),
    };

    test('quote the path for PowerShell', () {
      scripts.forEach((name, s) {
        expect(s, contains("'C:/Users/u/it''s here.txt'"), reason: name);
      });
    });

    test('hold no double quotes (they reach powershell.exe through the '
        'Windows command line)', () {
      scripts.forEach((name, s) {
        expect(s, isNot(contains('"')), reason: name);
      });
    });

    test('fail with exit 1 and the message on stderr as UTF-8 bytes', () {
      for (final name in [
        'list',
        'read',
        'write',
        'create file',
        'create directory',
      ]) {
        final s = scripts[name]!;
        expect(s, startsWith("try { \$ErrorActionPreference = 'Stop'; "));
        expect(s, contains('[Text.Encoding]::UTF8.GetBytes'), reason: name);
        expect(s, contains('[Console]::OpenStandardError()'), reason: name);
        expect(s, endsWith('exit 1 }'), reason: name);
      }
    });

    test('a path probe answers 0 or 1, and checks for a directory only '
        'when asked', () {
      expect(scripts['exists'], endsWith('{ exit 0 } else { exit 1 }'));
      expect(scripts['exists'], isNot(contains('Container')));
      expect(scripts['is directory'], contains('-PathType Container'));
    });

    test('a write reads stdin into a temporary file before touching the '
        'target', () {
      final s = scripts['write']!;
      final temp = s.indexOf('GetTempFileName');
      final copyIn = s.indexOf(r'$i.CopyTo($f)');
      final copyOut = s.indexOf('[IO.File]::Copy(');
      expect(temp, isNonNegative);
      expect(copyIn, greaterThan(temp));
      expect(copyOut, greaterThan(copyIn));
      expect(s, contains(r'finally { [IO.File]::Delete($t) }'));
      // The content travels on stdin, so the script is small whatever it is.
      expect(s.length, lessThan(1000));
    });
  });

  test('the POSIX write fills a temporary file before the target', () {
    final c = posixWriteCommand("/home/u/it's.txt");
    expect(c, startsWith(r't=$(mktemp) || exit 1; cat > "$t" && '));
    expect(c, contains(r'''cat < "$t" > '/home/u/it'\''s.txt';'''));
    expect(c, endsWith(r'rm -f "$t"; exit $s'));
  });
}

/// A [Workspace] that answers [exec] from a table of canned outputs.
class _Ws implements Workspace {
  _Ws(this.rootPath, this._outputs);

  @override
  final String rootPath;
  final Map<String, String> _outputs;
  final commands = <String>[];

  @override
  Future<WsExecResult> exec(String command, {String? cwd}) async {
    commands.add(command);
    final out = _outputs[command];
    return WsExecResult(
      exitCode: out == null ? 1 : 0,
      stdout: out ?? '',
      stderr: '',
    );
  }

  @override
  bool get isRemote => true;

  @override
  CommandRunner get commandRunner => throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}
