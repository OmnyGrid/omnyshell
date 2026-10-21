import 'package:command_shield/command_shield.dart' show CommandSyntax;
import 'package:path/path.dart' as p;

import '../ide_command_support.dart'
    show idePathContext, msysPath, normalizeIdePath, quoteForSyntax;
import '../workspace/workspace.dart';
import 'git_status.dart';

/// Runs git against a working directory (via the [Workspace], so it works on the
/// local fs or a remote node) and exposes the two queries the IDE needs:
/// working-tree [fileStatuses] (for the file tree) and a file's [lineGutter]
/// (for the editor's change gutter). All git invocations are best-effort: when
/// git is missing or the directory is not a repository, the methods return empty
/// results so the IDE works fine outside version control.
class GitRepo {
  GitRepo._(this._workspace, this.root, this._quote);

  final Workspace _workspace;

  /// The repository's top-level directory (absolute), in the workspace's own
  /// path form.
  final String root;

  /// Quotes an argument for the shell the workspace's commands run in.
  final String Function(String) _quote;

  /// Discovers the repository containing [dir], or `null` when [dir] is not in a
  /// git working tree (or git is unavailable).
  ///
  /// [syntax] is that of the shell the workspace's commands run in (the
  /// node's session shell), which decides how a path argument is quoted.
  static Future<GitRepo?> discover(
    Workspace workspace,
    String dir, {
    CommandSyntax syntax = CommandSyntax.bash,
  }) async {
    try {
      final res = await workspace.exec(
        'git rev-parse --show-toplevel',
        cwd: dir,
      );
      if (res.exitCode != 0) return null;
      final top = res.stdout.trim();
      if (top.isEmpty) return null;
      // git prints `/` paths (`C:/…`, `//server/share`); hold the root in
      // the workspace's own form so it compares with the tree's paths. Git
      // for Windows prints `C:/…` under Git Bash too, whose paths are `/c/…`.
      final paths = idePathContext(workspace.rootPath);
      final native = paths.style == p.Style.posix ? msysPath(top) ?? top : top;
      return GitRepo._(
        workspace,
        normalizeIdePath(paths, native),
        (s) => quoteForSyntax(s, syntax),
      );
    } on Object {
      return null;
    }
  }

  /// The working-tree status of every changed/untracked file, keyed by path
  /// relative to [root] (POSIX separators, as git emits).
  ///
  /// By default an untracked directory is reported once, as `dir/`. With
  /// [deep], every untracked file inside it is listed (`-uall`), which is
  /// slower on large trees but lets callers roll changes up to directories.
  Future<Map<String, GitFileStatus>> fileStatuses({bool deep = false}) async {
    final out = await _run(
      deep ? 'git status --porcelain -uall' : 'git status --porcelain',
    );
    if (out == null) return const {};
    return parseStatusPorcelain(out);
  }

  /// The per-line change gutter for [absPath]. Untracked files are reported as
  /// fully added; tracked files are diffed against the index/HEAD with `-U0` so
  /// only changed lines are marked.
  Future<LineGutter> lineGutter(String absPath, {int lineCount = 0}) async {
    final rel = idePathContext(
      root,
    ).relative(absPath, from: root).replaceAll(r'\', '/');
    final statuses = await fileStatuses();
    if (statuses[rel] == GitFileStatus.untracked) {
      final marks = <int, GutterMark>{
        for (var l = 1; l <= lineCount; l++) l: GutterMark.added,
      };
      return LineGutter(marks, const {});
    }
    final out = await _run('git diff -U0 --no-color -- ${_quote(rel)}');
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
