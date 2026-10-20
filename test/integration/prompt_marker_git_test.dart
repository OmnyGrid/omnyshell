@TestOn('vm')
@Tags(['windows'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// Runs the real prompt marker in a real shell, with and without `git` on the
/// PATH: git is optional on a node, and the marker must then stay silent and
/// report an empty branch rather than print a "command not found" error after
/// every command.
///
/// Tagged `windows` so the Windows CI job runs the PowerShell cases; the POSIX
/// cases self-skip there, and everything runs in the full Linux suite (whose
/// runner ships `pwsh`).
void main() {
  final git = _which('git');

  group('POSIX marker', () {
    final skip = Platform.isWindows ? 'POSIX shell only' : null;
    const dialect = PosixShellDialect();

    test('is silent and reports no branch when git is missing', () async {
      // A PATH holding only the tools the marker needs besides git.
      final bin = await _tempDir('nogit_bin');
      for (final tool in ['awk', 'id']) {
        final path = _which(tool);
        if (path != null) await Link('${bin.path}/$tool').create(path);
      }
      final work = await _tempDir('nogit_work');
      final r = await _runMarker(
        dialect,
        ['/bin/sh', '-c'],
        cwd: work.path,
        path: bin.path,
      );
      expect(r.stderr, isEmpty);
      expect(r.scan.cwd, _samePath(work.path));
      expect(r.scan.branch, isNull);
      expect(r.scan.gitStatus, isNull);
    }, skip: skip);

    test('reports the branch and status when git is present', () async {
      final repo = await _gitRepo(git!);
      final r = await _runMarker(
        dialect,
        ['/bin/sh', '-c'],
        cwd: repo.path,
        path: Platform.environment['PATH']!,
      );
      expect(r.stderr, isEmpty);
      expect(r.scan.branch, 'trunk');
      expect(r.scan.gitStatus, '+0 ~0 ?1');
    }, skip: skip ?? (git == null ? 'git not installed' : null));
  });

  group('PowerShell marker', () {
    final ps = _which('pwsh') ?? _which('powershell');
    final skip = ps == null ? 'PowerShell not installed' : null;
    const dialect = PowerShellDialect();
    final argv = [ps ?? '', '-NoProfile', '-NonInteractive', '-Command'];

    test('is silent and reports no branch when git is missing', () async {
      // Keep every PATH entry except those holding a git executable, so
      // PowerShell itself still starts.
      final sep = Platform.isWindows ? ';' : ':';
      final path = Platform.environment['PATH']!
          .split(sep)
          .where((d) => !_hasGit(d))
          .join(sep);
      final work = await _tempDir('nogit_work');
      final r = await _runMarker(dialect, argv, cwd: work.path, path: path);
      expect(r.stderr, isNot(contains('git')));
      expect(r.stdout, isNot(contains('CommandNotFoundException')));
      expect(r.scan.cwd, _samePath(work.path));
      expect(r.scan.branch, isNull);
      expect(r.scan.gitStatus, isNull);
    }, skip: skip);

    test('reports the branch and status when git is present', () async {
      final repo = await _gitRepo(git!);
      final r = await _runMarker(
        dialect,
        argv,
        cwd: repo.path,
        path: Platform.environment['PATH']!,
      );
      expect(r.stderr, isEmpty);
      expect(r.scan.branch, 'trunk');
      expect(r.scan.gitStatus, '+0 ~0 ?1');
    }, skip: skip ?? (git == null ? 'git not installed' : null));
  });
}

typedef _MarkerRun = ({String stdout, String stderr, CwdScan scan});

/// Runs [dialect]'s full marker as the last argument of [argv] in [cwd] with
/// PATH set to [path], and parses its output with a [CwdMarker].
Future<_MarkerRun> _runMarker(
  ShellDialect dialect,
  List<String> argv, {
  required String cwd,
  required String path,
}) async {
  final marker = CwdMarker('itest');
  final env = Map.of(Platform.environment);
  // Windows env keys are case-insensitive; drop every spelling of PATH.
  env.removeWhere((k, _) => k.toUpperCase() == 'PATH');
  env['PATH'] = path;
  final result = await Process.run(
    argv.first,
    [...argv.skip(1), dialect.fullMarker(marker)],
    workingDirectory: cwd,
    environment: env,
    includeParentEnvironment: false,
    stdoutEncoding: null,
  ).timeout(const Duration(seconds: 60));
  final out = result.stdout as List<int>;
  return (
    stdout: utf8.decode(out, allowMalformed: true),
    stderr: (result.stderr as String).trim(),
    scan: marker.feed(Uint8List.fromList(out)),
  );
}

/// A git repo on branch `trunk` with one untracked file.
Future<Directory> _gitRepo(String git) async {
  final dir = await _tempDir('git_repo');
  final init = await Process.run(git, [
    'init',
    '-q',
    '-b',
    'trunk',
  ], workingDirectory: dir.path);
  expect(init.exitCode, 0, reason: '${init.stderr}');
  // A commit, so HEAD is born and `rev-parse --abbrev-ref HEAD` names it.
  final commit = await Process.run(git, [
    '-c',
    'user.name=t',
    '-c',
    'user.email=t@t',
    'commit',
    '-q',
    '--allow-empty',
    '-m',
    'init',
  ], workingDirectory: dir.path);
  expect(commit.exitCode, 0, reason: '${commit.stderr}');
  await File('${dir.path}/new.txt').writeAsString('x');
  return dir;
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

bool _hasGit(String dir) =>
    File('$dir/git').existsSync() || File('$dir/git.exe').existsSync();

/// The full path of [tool] on the current PATH, or `null`.
String? _which(String tool) {
  final r = Process.runSync(Platform.isWindows ? 'where' : 'which', [tool]);
  if (r.exitCode != 0) return null;
  final first = (r.stdout as String).split(RegExp(r'\r?\n')).first.trim();
  return first.isEmpty ? null : first;
}
