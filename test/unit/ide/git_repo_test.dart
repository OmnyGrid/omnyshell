@TestOn('vm')
library;

import 'package:omnyshell/src/application/client/ide/git/git_repo.dart';
import 'package:omnyshell/src/application/client/ide/git/git_status.dart';
import 'package:omnyshell/src/application/client/ide/terminal/command_runner.dart';
import 'package:omnyshell/src/application/client/ide/workspace/workspace.dart';
import 'package:test/test.dart';

/// A [Workspace] that answers `exec` from a script, so git behaviour can be
/// exercised without a repository (or git) being present.
class _FakeWorkspace implements Workspace {
  _FakeWorkspace(this._answer);

  /// Maps a command line to its result; a missing entry means "git said
  /// nothing useful" (exit 1).
  final WsExecResult Function(String command) _answer;

  /// Every command run, in order, with the cwd it was run in.
  final List<(String, String?)> calls = [];

  @override
  Future<WsExecResult> exec(String command, {String? cwd}) async {
    calls.add((command, cwd));
    return _answer(command);
  }

  @override
  String get rootPath => '/repo';

  @override
  bool get isRemote => false;

  @override
  CommandRunner get commandRunner => throw UnimplementedError();

  @override
  Future<void> close() async {}

  @override
  Future<void> createDirectory(String absPath) => throw UnimplementedError();

  @override
  Future<void> createFile(String absPath) => throw UnimplementedError();

  @override
  Future<bool> exists(String absPath) => throw UnimplementedError();

  @override
  Future<bool> isDirectory(String absPath) => throw UnimplementedError();

  @override
  Future<List<WsEntry>> list(String absPath) => throw UnimplementedError();

  @override
  Future<String> read(String absPath) => throw UnimplementedError();

  @override
  Future<void> write(String absPath, String content) =>
      throw UnimplementedError();
}

WsExecResult _ok(String stdout) =>
    WsExecResult(exitCode: 0, stdout: stdout, stderr: '');

const _failed = WsExecResult(exitCode: 1, stdout: '', stderr: 'fatal');

/// A workspace whose commands are answered from [replies]; anything not listed
/// fails the way git does outside a repository.
_FakeWorkspace _workspace(Map<String, WsExecResult> replies) =>
    _FakeWorkspace((command) => replies[command] ?? _failed);

/// A repo discovered over [replies], with `rev-parse --show-toplevel` answered.
Future<GitRepo> _repo(
  Map<String, WsExecResult> replies, {
  String root = '/repo',
}) async {
  final ws = _workspace({
    'git rev-parse --show-toplevel': _ok('$root\n'),
    ...replies,
  });
  return (await GitRepo.discover(ws, root))!;
}

void main() {
  group('GitRepo.discover', () {
    test('returns the repository top level, normalised', () async {
      final ws = _workspace({
        'git rev-parse --show-toplevel': _ok('/repo/./sub/..\n'),
      });

      final repo = await GitRepo.discover(ws, '/repo/sub');

      expect(repo, isNotNull);
      expect(repo!.root, '/repo');
      expect(ws.calls.single.$2, '/repo/sub', reason: 'asked from that dir');
    });

    test('gives up outside a working tree', () async {
      final repo = await GitRepo.discover(_workspace(const {}), '/tmp');

      expect(repo, isNull);
    });

    test('gives up when git answers with nothing', () async {
      final ws = _workspace({'git rev-parse --show-toplevel': _ok('  \n')});

      expect(await GitRepo.discover(ws, '/tmp'), isNull);
    });

    test('gives up when git cannot be run at all', () async {
      final ws = _FakeWorkspace((_) => throw const ProcessMissing());

      expect(await GitRepo.discover(ws, '/tmp'), isNull);
    });
  });

  group('GitRepo.fileStatuses', () {
    test('parses the porcelain status', () async {
      final repo = await _repo({
        'git status --porcelain': _ok(' M lib/a.dart\n?? new.txt\n'),
      });

      expect(await repo.fileStatuses(), {
        'lib/a.dart': GitFileStatus.modified,
        'new.txt': GitFileStatus.untracked,
      });
    });

    test('is empty when git fails', () async {
      final repo = await _repo(const {});

      expect(await repo.fileStatuses(), isEmpty);
    });
  });

  group('GitRepo.lineGutter', () {
    test('marks every line of an untracked file as added', () async {
      final repo = await _repo({
        'git status --porcelain': _ok('?? new.dart\n'),
      });

      final gutter = await repo.lineGutter('/repo/new.dart', lineCount: 3);

      expect(gutter.marks, {
        1: GutterMark.added,
        2: GutterMark.added,
        3: GutterMark.added,
      });
      expect(gutter.deletionsBefore, isEmpty);
    });

    test('diffs a tracked file against the index', () async {
      final repo = await _repo({
        'git status --porcelain': _ok(' M lib/a.dart\n'),
        "git diff -U0 --no-color -- 'lib/a.dart'": _ok(
          '--- a/lib/a.dart\n'
          '+++ b/lib/a.dart\n'
          '@@ -2,0 +3 @@\n'
          '+added line\n',
        ),
      });

      final gutter = await repo.lineGutter('/repo/lib/a.dart');

      expect(gutter.marks, {3: GutterMark.added});
    });

    test('quotes a path that contains a quote', () async {
      final ws = _workspace({
        'git rev-parse --show-toplevel': _ok('/repo\n'),
        'git status --porcelain': _ok(''),
      });
      final repo = (await GitRepo.discover(ws, '/repo'))!;

      await repo.lineGutter("/repo/it's.dart");

      expect(ws.calls.last.$1, "git diff -U0 --no-color -- 'it'\\''s.dart'");
    });

    test('is empty when the file has no diff', () async {
      final repo = await _repo({
        'git status --porcelain': _ok(''),
        "git diff -U0 --no-color -- 'lib/a.dart'": _ok('   \n'),
      });

      expect((await repo.lineGutter('/repo/lib/a.dart')).isEmpty, isTrue);
    });

    test('is empty when git fails', () async {
      final repo = await _repo(const {});

      expect((await repo.lineGutter('/repo/lib/a.dart')).isEmpty, isTrue);
    });
  });

  group('GitRepo.currentBranch', () {
    test('reports the checked-out branch', () async {
      final repo = await _repo({
        'git rev-parse --abbrev-ref HEAD': _ok('feature/x\n'),
      });

      expect(await repo.currentBranch(), 'feature/x');
    });

    test('names a detached HEAD as such', () async {
      final repo = await _repo({
        'git rev-parse --abbrev-ref HEAD': _ok('HEAD\n'),
      });

      expect(await repo.currentBranch(), '(detached)');
    });

    test('is null when git answers with nothing', () async {
      final repo = await _repo({'git rev-parse --abbrev-ref HEAD': _ok('\n')});

      expect(await repo.currentBranch(), isNull);
    });

    test('is null when git fails', () async {
      final repo = await _repo(const {});

      expect(await repo.currentBranch(), isNull);
    });
  });
}

/// Stands in for "git is not installed", which reaches [GitRepo] as a throw.
class ProcessMissing implements Exception {
  const ProcessMissing();
}
