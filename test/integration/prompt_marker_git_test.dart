@TestOn('vm')
@Tags(['windows'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// Runs the real prompt marker in a real shell: the branch and status parsed
/// from the one `git status --porcelain -b` it runs, the values it caches for
/// the session, and staying silent when git is not installed (git is optional
/// on a node; a missing git must not print a "command not found" error after
/// every command).
///
/// Tagged `windows` so the Windows CI job runs the PowerShell cases; the POSIX
/// cases self-skip there, and everything runs in the full Linux suite (whose
/// runner ships `pwsh`).
void main() {
  final git = _which('git');
  final ps = _which('pwsh') ?? _which('powershell');
  final shells = [
    _Shell(
      'POSIX',
      const PosixShellDialect(),
      const ['/bin/sh', '-c'],
      skip: Platform.isWindows ? 'POSIX shell only' : null,
      pinPrivilege: '__omny_pv=pinned',
      pinNoGit: null,
      exitCodes: {'true': 0, 'false': 1, "sh -c 'exit 3'": 3},
    ),
    _Shell(
      'PowerShell',
      const PowerShellDialect(),
      [ps ?? '', '-NoProfile', '-NonInteractive', '-Command'],
      skip: ps == null ? 'PowerShell not installed' : null,
      pinPrivilege: r"$global:__omnyPv='pinned'",
      pinNoGit: r'$global:__omnyGit=$false',
      exitCodes: {
        'Write-Output hi': 0,
        // A failed cmdlet sets no exit code of its own.
        'Get-Item -LiteralPath ./no-such-file': 1,
        // A native program's code is reported as is.
        "& '$ps' -NoProfile -NonInteractive -Command 'exit 3'": 3,
        // A line that fails after a program in it succeeded: $LASTEXITCODE
        // is 0, but the line failed.
        "& '$ps' -NoProfile -NonInteractive -Command 'exit 0'; "
                'Get-Item -LiteralPath ./no-such-file':
            1,
      },
    ),
  ];

  for (final shell in shells) {
    final gitSkip = shell.skip ?? (git == null ? 'git not installed' : null);

    group('${shell.name} marker', () {
      test('is silent and reports no branch when git is missing', () async {
        final work = await _tempDir('nogit_work');
        final r = await shell.run(
          cwd: work.path,
          path: await _pathWithoutGit(),
        );
        expect(r.stderr, isEmpty);
        expect(r.stdout, isNot(contains('CommandNotFoundException')));
        expect(r.scan.cwd, _samePath(work.path));
        expect(r.scan.branch, isNull);
        expect(r.scan.gitStatus, isNull);
      }, skip: shell.skip);

      test('reports the branch and status', () async {
        final repo = await _gitRepo(git!);
        await File('${repo.path}/new.txt').writeAsString('x');
        final r = await shell.run(cwd: repo.path);
        expect(r.stderr, isEmpty);
        expect(r.scan.cwd, _samePath(repo.path));
        expect(r.scan.branch, 'trunk');
        expect(r.scan.gitStatus, '+0 ~0 ?1');
      }, skip: gitSkip);

      test('counts staged and modified files', () async {
        final repo = await _gitRepo(git!);
        await File('${repo.path}/a.txt').writeAsString('a');
        await File('${repo.path}/b.txt').writeAsString('b');
        await _git(git, repo, ['add', 'a.txt', 'b.txt']);
        await File('${repo.path}/b.txt').writeAsString('b2');
        final r = await shell.run(cwd: repo.path);
        // a.txt staged; b.txt staged and modified again.
        expect(r.scan.gitStatus, '+2 ~1 ?0');
      }, skip: gitSkip);

      test('reports a clean repo with an empty status', () async {
        final repo = await _gitRepo(git!);
        final r = await shell.run(cwd: repo.path);
        expect(r.scan.branch, 'trunk');
        expect(r.scan.gitStatus, isNull);
      }, skip: gitSkip);

      test('names the branch of a repo with no commits yet', () async {
        final repo = await _gitRepo(git!, commit: false);
        final r = await shell.run(cwd: repo.path);
        expect(r.stderr, isEmpty);
        expect(r.scan.branch, 'trunk');
      }, skip: gitSkip);

      test('names the branch inside .git, where git status fails', () async {
        final repo = await _gitRepo(git!);
        final r = await shell.run(
          cwd: '${repo.path}${Platform.pathSeparator}.git',
        );
        expect(r.stderr, isEmpty);
        expect(r.scan.branch, 'trunk');
        expect(r.scan.gitStatus, isNull);
      }, skip: gitSkip);

      test('reports HEAD when detached', () async {
        final repo = await _gitRepo(git!);
        await _git(git, repo, ['checkout', '-q', '--detach']);
        final r = await shell.run(cwd: repo.path);
        expect(r.scan.branch, 'HEAD');
      }, skip: gitSkip);

      test('strips the upstream and ahead/behind from the branch', () async {
        final repo = await _gitRepo(git!);
        await _git(git, repo, [
          'update-ref',
          'refs/remotes/origin/trunk',
          'HEAD',
        ]);
        await _git(git, repo, ['config', 'branch.trunk.remote', 'origin']);
        await _git(git, repo, [
          'config',
          'branch.trunk.merge',
          'refs/heads/trunk',
        ]);
        await _git(git, repo, [
          ..._identity,
          'commit',
          '-q',
          '--allow-empty',
          '-m',
          'two',
        ]);
        final r = await shell.run(cwd: repo.path);
        expect(r.scan.branch, 'trunk');
      }, skip: gitSkip);

      test('reports the branch on every marker of a session', () async {
        final repo = await _gitRepo(git!);
        final r = await shell.run(cwd: repo.path, markers: 2);
        expect(r.stderr, isEmpty);
        expect(r.markersSeen, 2);
        expect(r.scan.branch, 'trunk');
      }, skip: gitSkip);

      test('reuses the privilege cached for the session', () async {
        final work = await _tempDir('pv_work');
        final r = await shell.run(cwd: work.path, prelude: shell.pinPrivilege);
        expect(r.scan.privilege, 'pinned');
      }, skip: shell.skip);

      if (shell.pinNoGit != null) {
        test('reuses the git presence cached for the session', () async {
          final repo = await _gitRepo(git!);
          final r = await shell.run(cwd: repo.path, prelude: shell.pinNoGit);
          // Cached as absent, so no git query runs even inside a repo.
          expect(r.scan.branch, isNull);
        }, skip: gitSkip);
      }

      if (shell.dialect is PowerShellDialect) {
        // Prints the user's $LASTEXITCODE as seen after the marker.
        const showLc =
            r'[Console]::Out.Write("LC=[$LASTEXITCODE]"+'
            r'(Test-Path variable:global:LASTEXITCODE))';
        final exit3 = "& '$ps' -NoProfile -NonInteractive -Command 'exit 3'";

        test(r'keeps the user $LASTEXITCODE across its git call', () async {
          // Outside a repo, where the marker's git status exits 128.
          final work = await _tempDir('lc_work');
          final r = await shell.run(
            cwd: work.path,
            prelude: exit3,
            after: showLc,
          );
          expect(r.scan.cwd, _samePath(work.path));
          expect(r.stdout, contains('LC=[3]True'));
        }, skip: gitSkip);

        test(r'keeps $LASTEXITCODE across the agent marker too', () async {
          final repo = await _gitRepo(git!);
          final r = await shell.run(
            cwd: repo.path,
            agentLine: exit3,
            after: showLc,
          );
          expect(r.scan.exitCode, 3);
          expect(r.stdout, contains('LC=[3]True'));
        }, skip: gitSkip);

        test('a failed cmdlet after a failed program reports 1, not the '
            "program's stale code", () async {
          final repo = await _gitRepo(git!);
          final r = await shell.run(
            cwd: repo.path,
            prelude: exit3,
            agentLine: 'Get-Item -LiteralPath ./no-such-file',
            after: showLc,
          );
          expect(r.scan.exitCode, 1);
          // The cmdlet set no code, so the user's previous one is kept.
          expect(r.stdout, contains('LC=[3]True'));
        }, skip: gitSkip);

        test(r'leaves $LASTEXITCODE unset when it was unset', () async {
          final repo = await _gitRepo(git!);
          final r = await shell.run(cwd: repo.path, after: showLc);
          expect(r.scan.branch, 'trunk'); // git did run
          expect(r.stdout, contains('LC=[]False'));
        }, skip: gitSkip);
      }

      for (final MapEntry(key: line, value: code) in shell.exitCodes.entries) {
        test('agent marker reports exit code $code for `$line`', () async {
          final repo = await _gitRepo(git!);
          final r = await shell.run(cwd: repo.path, agentLine: line);
          expect(r.markersSeen, 1);
          expect(r.scan.exitCode, code);
          // The other fields are still reported alongside it.
          expect(r.scan.cwd, _samePath(repo.path));
          expect(r.scan.branch, 'trunk');
        }, skip: gitSkip);
      }
    });
  }
}

/// A shell to run the marker in, with the statements that pin its cached
/// values (null where the dialect caches no such value).
class _Shell {
  final String name;
  final ShellDialect dialect;
  final List<String> argv;
  final String? skip;
  final String pinPrivilege;
  final String? pinNoGit;

  /// Commands mapped to the exit code the agent marker must report.
  final Map<String, int> exitCodes;

  _Shell(
    this.name,
    this.dialect,
    this.argv, {
    required this.skip,
    required this.pinPrivilege,
    required this.pinNoGit,
    required this.exitCodes,
  });

  /// Runs the init line, an optional [prelude], then [markers] full markers,
  /// as the client primes a session, in [cwd] with PATH set to [path] (the
  /// current PATH by default), and parses the output with a [CwdMarker].
  ///
  /// With [agentLine], runs that line wrapped with the agent marker instead
  /// of the full markers, as the AI agent does. [after] runs last.
  Future<_MarkerRun> run({
    required String cwd,
    String? path,
    String? prelude,
    int markers = 1,
    String? agentLine,
    String? after,
  }) async {
    final marker = CwdMarker('itest');
    final env = Map.of(Platform.environment);
    // Windows env keys are case-insensitive; drop every spelling of PATH.
    final current = env.entries
        .firstWhere((e) => e.key.toUpperCase() == 'PATH')
        .value;
    env.removeWhere((k, _) => k.toUpperCase() == 'PATH');
    env['PATH'] = path ?? current;
    final script = [
      ?dialect.initLine,
      ?prelude,
      if (agentLine != null)
        // As `InteractiveShellController.runAgentCommand` does.
        dialect.wrapCommand(
          dialect.agentLine(agentLine),
          interactive: false,
          tail: dialect.agentMarker(marker),
        )
      else
        for (var i = 0; i < markers; i++) dialect.fullMarker(marker),
      ?after,
    ].join('\n');
    final result = await Process.run(
      argv.first,
      [...argv.skip(1), script],
      workingDirectory: cwd,
      environment: env,
      includeParentEnvironment: false,
      stdoutEncoding: null,
    ).timeout(const Duration(seconds: 60));
    final out = result.stdout as List<int>;
    final stdout = utf8.decode(out, allowMalformed: true);
    return (
      stdout: stdout,
      stderr: (result.stderr as String).trim(),
      scan: marker.feed(Uint8List.fromList(out)),
      markersSeen: marker.token.allMatches(stdout).length,
    );
  }
}

typedef _MarkerRun = ({
  String stdout,
  String stderr,
  CwdScan scan,
  int markersSeen,
});

const _identity = ['-c', 'user.name=t', '-c', 'user.email=t@t'];

/// A git repo on branch `trunk`, with one empty commit unless [commit] is
/// false.
Future<Directory> _gitRepo(String git, {bool commit = true}) async {
  final dir = await _tempDir('git_repo');
  await _git(git, dir, ['init', '-q', '-b', 'trunk']);
  if (commit) {
    await _git(git, dir, [
      ..._identity,
      'commit',
      '-q',
      '--allow-empty',
      '-m',
      'init',
    ]);
  }
  return dir;
}

Future<void> _git(String git, Directory repo, List<String> args) async {
  final r = await Process.run(git, args, workingDirectory: repo.path);
  expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
}

/// A PATH without git. On Windows, every current entry except those holding
/// git, so PowerShell itself still starts. Elsewhere, a directory linking only
/// the tools the markers need besides git: those entries also hold the shells
/// on macOS (/usr/bin/git), so they cannot simply be dropped; the shells are
/// run by absolute path.
Future<String> _pathWithoutGit() async {
  if (Platform.isWindows) {
    return Platform.environment['PATH']!
        .split(';')
        .where((d) => !_hasGit(d))
        .join(';');
  }
  final bin = await _tempDir('nogit_bin');
  for (final tool in ['awk', 'id', 'pwsh']) {
    final path = _which(tool);
    if (path != null) await Link('${bin.path}/$tool').create(path);
  }
  return bin.path;
}

Future<Directory> _tempDir(String name) async {
  final dir = await Directory.systemTemp.createTemp('omny_$name');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Best-effort: Windows may briefly hold a just-exited shell's cwd.
    }
  });
  return dir;
}

/// Matches [expected] after resolving symlinks (macOS's /var → /private/var)
/// and ignoring case on Windows.
Matcher _samePath(String expected) {
  String norm(String p) {
    final r = Directory(p).resolveSymbolicLinksSync();
    return Platform.isWindows ? r.toLowerCase() : r;
  }

  return predicate<String?>(
    (p) => p != null && norm(p) == norm(expected),
    'is the same path as $expected',
  );
}

/// Whether [dir] holds a git executable or shim (scoop/chocolatey may ship
/// `git.cmd`/`git.bat`).
bool _hasGit(String dir) => [
  'git',
  'git.exe',
  'git.cmd',
  'git.bat',
].any((name) => File('$dir/$name').existsSync());

/// The full path of [tool] on the current PATH, or `null` (also when there is
/// no `which`/`where` to ask).
String? _which(String tool) {
  final ProcessResult r;
  try {
    r = Process.runSync(Platform.isWindows ? 'where' : 'which', [tool]);
  } on ProcessException {
    return null;
  }
  if (r.exitCode != 0) return null;
  final first = (r.stdout as String).split(RegExp(r'\r?\n')).first.trim();
  return first.isEmpty ? null : first;
}
