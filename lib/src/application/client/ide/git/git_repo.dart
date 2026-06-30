import 'package:path/path.dart' as p;

import '../workspace/workspace.dart';
import 'git_status.dart';

/// Runs git against a working directory (via the [Workspace], so it works on the
/// local fs or a remote node) and exposes the two queries the IDE needs:
/// working-tree [fileStatuses] (for the file tree) and a file's [lineGutter]
/// (for the editor's change gutter). All git invocations are best-effort: when
/// git is missing or the directory is not a repository, the methods return empty
/// results so the IDE works fine outside version control.
class GitRepo {
  GitRepo._(this._workspace, this.root);

  final Workspace _workspace;

  /// The repository's top-level directory (absolute).
  final String root;

  /// Single-quotes [s] for safe POSIX shell interpolation.
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// Discovers the repository containing [dir], or `null` when [dir] is not in a
  /// git working tree (or git is unavailable).
  static Future<GitRepo?> discover(Workspace workspace, String dir) async {
    try {
      final res = await workspace.exec(
        'git rev-parse --show-toplevel',
        cwd: dir,
      );
      if (res.exitCode != 0) return null;
      final top = res.stdout.trim();
      if (top.isEmpty) return null;
      return GitRepo._(workspace, p.normalize(top));
    } on Object {
      return null;
    }
  }

  /// The working-tree status of every changed/untracked file, keyed by path
  /// relative to [root] (POSIX separators, as git emits).
  Future<Map<String, GitFileStatus>> fileStatuses() async {
    final out = await _run('git status --porcelain');
    if (out == null) return const {};
    return parseStatusPorcelain(out);
  }

  /// The per-line change gutter for [absPath]. Untracked files are reported as
  /// fully added; tracked files are diffed against the index/HEAD with `-U0` so
  /// only changed lines are marked.
  Future<LineGutter> lineGutter(String absPath, {int lineCount = 0}) async {
    final rel = p.relative(absPath, from: root).replaceAll(r'\', '/');
    final statuses = await fileStatuses();
    if (statuses[rel] == GitFileStatus.untracked) {
      final marks = <int, GutterMark>{
        for (var l = 1; l <= lineCount; l++) l: GutterMark.added,
      };
      return LineGutter(marks, const {});
    }
    final out = await _run('git diff -U0 --no-color -- ${_q(rel)}');
    if (out == null || out.trim().isEmpty) return LineGutter.empty;
    return parseUnifiedDiffGutter(out);
  }

  /// The current branch name, `(detached)` when on a detached HEAD, or `null`
  /// when unavailable.
  Future<String?> currentBranch() async {
    final out = await _run('git rev-parse --abbrev-ref HEAD');
    final branch = out?.trim();
    if (branch == null || branch.isEmpty) return null;
    return branch == 'HEAD' ? '(detached)' : branch;
  }

  Future<String?> _run(String command) async {
    try {
      final res = await _workspace.exec(command, cwd: root);
      if (res.exitCode != 0) return null;
      return res.stdout;
    } on Object {
      return null;
    }
  }
}
