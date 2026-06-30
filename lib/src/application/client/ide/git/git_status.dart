/// Git change information for the IDE: a file's working-tree status (for the
/// file tree) and a file's per-line gutter marks (for the editor). The pure
/// parsers in this file turn `git status --porcelain` and `git diff` output into
/// these models; running git lives in `git_repo.dart`.
library;

/// A file's working-tree status against the index/HEAD.
enum GitFileStatus {
  clean,
  modified,
  added,
  deleted,
  untracked,
  renamed,
  ignored,
  conflicted,
}

/// The change kind of a single editor line.
enum GutterMark { added, modified }

/// Per-line change marks for one file: [marks] gives the kind of each changed
/// line (1-based, post-image line numbers), and [deletionsBefore] holds the
/// 1-based lines that have one or more deleted lines immediately above them.
class LineGutter {
  const LineGutter(this.marks, this.deletionsBefore);

  final Map<int, GutterMark> marks;
  final Set<int> deletionsBefore;

  /// An empty gutter (no changes).
  static const empty = LineGutter({}, {});

  bool get isEmpty => marks.isEmpty && deletionsBefore.isEmpty;
}

/// Parses `git status --porcelain` [output] into a map of repo-relative path →
/// [GitFileStatus]. Renames map both the old and new path. Unparseable lines are
/// skipped.
Map<String, GitFileStatus> parseStatusPorcelain(String output) {
  final result = <String, GitFileStatus>{};
  for (final raw in output.split('\n')) {
    if (raw.length < 3) continue;
    final x = raw[0]; // index status
    final y = raw[1]; // worktree status
    var rest = raw.substring(3);
    if (x == '?' && y == '?') {
      result[_unquote(rest)] = GitFileStatus.untracked;
      continue;
    }
    if (x == '!' && y == '!') {
      result[_unquote(rest)] = GitFileStatus.ignored;
      continue;
    }
    if (x == 'U' ||
        y == 'U' ||
        (x == 'A' && y == 'A') ||
        (x == 'D' && y == 'D')) {
      result[_unquote(rest)] = GitFileStatus.conflicted;
      continue;
    }
    if (x == 'R' || y == 'R') {
      // "old -> new"
      final arrow = rest.indexOf(' -> ');
      if (arrow >= 0) {
        final oldPath = _unquote(rest.substring(0, arrow));
        final newPath = _unquote(rest.substring(arrow + 4));
        result[oldPath] = GitFileStatus.renamed;
        result[newPath] = GitFileStatus.renamed;
        continue;
      }
      rest = _unquote(rest);
      result[rest] = GitFileStatus.renamed;
      continue;
    }
    final code = x != ' ' ? x : y;
    final status = switch (code) {
      'A' => GitFileStatus.added,
      'M' => GitFileStatus.modified,
      'D' => GitFileStatus.deleted,
      'C' => GitFileStatus.added,
      'T' => GitFileStatus.modified,
      _ => GitFileStatus.modified,
    };
    result[_unquote(rest)] = status;
  }
  return result;
}

/// Parses a unified `git diff` [output] for a single file into a [LineGutter].
///
/// Added lines with no paired removal are [GutterMark.added]; added lines that
/// replace removed lines are [GutterMark.modified]; removals with no
/// replacement are recorded in [LineGutter.deletionsBefore]. Works with both
/// `-U0` and context diffs.
LineGutter parseUnifiedDiffGutter(String output) {
  final marks = <int, GutterMark>{};
  final deletions = <int>{};
  final lines = output.split('\n');

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (!line.startsWith('@@')) {
      i++;
      continue;
    }
    final header = _parseHunkHeader(line);
    if (header == null) {
      i++;
      continue;
    }
    // Collect the hunk body (until the next hunk header or end).
    final body = <String>[];
    i++;
    while (i < lines.length && !lines[i].startsWith('@@')) {
      final l = lines[i];
      // Stop if we run into a new file header inside combined output.
      if (l.startsWith('diff ') ||
          l.startsWith('--- ') ||
          l.startsWith('+++ ')) {
        break;
      }
      body.add(l);
      i++;
    }
    _applyHunk(header.newStart, body, marks, deletions);
  }
  return LineGutter(marks, deletions);
}

class _HunkHeader {
  const _HunkHeader(this.newStart);
  final int newStart;
}

final _hunkRe = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@');

_HunkHeader? _parseHunkHeader(String line) {
  final m = _hunkRe.firstMatch(line);
  if (m == null) return null;
  return _HunkHeader(int.parse(m.group(1)!));
}

void _applyHunk(
  int newStart,
  List<String> body,
  Map<int, GutterMark> marks,
  Set<int> deletions,
) {
  final additions = <int>[]; // post-image line numbers of '+' lines
  var removals = 0;
  var newLine = newStart;
  for (final l in body) {
    if (l.startsWith('+')) {
      additions.add(newLine);
      newLine++;
    } else if (l.startsWith('-')) {
      removals++;
    } else {
      // Context line (' ' or empty).
      newLine++;
    }
  }
  final paired = removals < additions.length ? removals : additions.length;
  for (var k = 0; k < additions.length; k++) {
    marks[additions[k]] = k < paired ? GutterMark.modified : GutterMark.added;
  }
  if (removals > additions.length) {
    // Leftover deletions with no replacement line.
    final at = additions.isEmpty
        ? (newStart < 1 ? 1 : newStart)
        : additions.last + 1;
    deletions.add(at);
  }
}

/// Removes git's optional quoting/escaping of paths with unusual characters.
/// Plain paths pass through unchanged.
String _unquote(String path) {
  final p = path.trim();
  if (p.length >= 2 && p.startsWith('"') && p.endsWith('"')) {
    return p
        .substring(1, p.length - 1)
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\');
  }
  return p;
}
