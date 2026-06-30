import 'dart:io';

import 'package:path/path.dart' as p;

import 'git_status.dart';

/// Runs git against a working directory and exposes the two queries the IDE
/// needs: working-tree [fileStatuses] (for the file tree) and a file's
/// [lineGutter] (for the editor's change gutter). All git invocations are
/// best-effort: when git is missing or the directory is not a repository, the
/// methods return empty results so the IDE works fine outside version control.
class GitRepo {
  GitRepo._(this.root);

  /// The repository's top-level directory (absolute).
  final String root;

  /// Discovers the repository containing [dir], or `null` when [dir] is not in a
  /// git working tree (or git is unavailable).
  static GitRepo? discover(String dir) {
    try {
      final res = Process.runSync('git', [
        'rev-parse',
        '--show-toplevel',
      ], workingDirectory: dir);
      if (res.exitCode != 0) return null;
      final top = (res.stdout as String).trim();
      if (top.isEmpty) return null;
      return GitRepo._(p.normalize(top));
    } on Object {
      return null;
    }
  }

  /// The working-tree status of every changed/untracked file, keyed by path
  /// relative to [root] (POSIX separators, as git emits).
  Map<String, GitFileStatus> fileStatuses() {
    final out = _run(['status', '--porcelain']);
    if (out == null) return const {};
    return parseStatusPorcelain(out);
  }

  /// The per-line change gutter for [absPath]. Untracked files are reported as
  /// fully added; tracked files are diffed against the index/HEAD with `-U0` so
  /// only changed lines are marked.
  LineGutter lineGutter(String absPath, {int lineCount = 0}) {
    final rel = p.relative(absPath, from: root).replaceAll(r'\', '/');
    final statuses = fileStatuses();
    if (statuses[rel] == GitFileStatus.untracked) {
      // Whole file is new: mark every line as added.
      final marks = <int, GutterMark>{
        for (var l = 1; l <= lineCount; l++) l: GutterMark.added,
      };
      return LineGutter(marks, const {});
    }
    final out = _run(['diff', '-U0', '--no-color', '--', rel]);
    if (out == null || out.trim().isEmpty) return LineGutter.empty;
    return parseUnifiedDiffGutter(out);
  }

  /// The current branch name, `(detached)` when on a detached HEAD, or `null`
  /// when unavailable.
  String? currentBranch() {
    final out = _run(['rev-parse', '--abbrev-ref', 'HEAD']);
    final branch = out?.trim();
    if (branch == null || branch.isEmpty) return null;
    return branch == 'HEAD' ? '(detached)' : branch;
  }

  String? _run(List<String> args) {
    try {
      final res = Process.runSync('git', args, workingDirectory: root);
      if (res.exitCode != 0) return null;
      return res.stdout as String;
    } on Object {
      return null;
    }
  }
}
