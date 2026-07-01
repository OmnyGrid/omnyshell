/// Formats the interactive shell prompt — `user@node:cwd (git) $` — shared by
/// the native CLI connect loop and web clients so the prompt looks the same
/// everywhere. Pure string assembly with no I/O, so it compiles to JavaScript.
///
/// When [color] is true, segments are ANSI-colored: `user@node` green, `cwd`
/// cyan, the git segment blue with a red branch and green status counts, and the
/// privilege warning bold red. When false (e.g. `NO_COLOR` or a non-TTY) a plain
/// prompt is returned. A `(⚠ privilege)` segment appears only when [privilege]
/// is set (superuser). [branch]/[gitStatus] render a `git(...)` segment when a
/// branch is present.
///
/// When [width] is a positive terminal column count, the prompt shrinks
/// progressively to fit: the least-aggressive level whose visible width leaves at
/// least [_typingRoom] columns free is chosen, dropping the git status counts,
/// then `@node`, then shortening `cwd` to `…/basename`, then the whole git
/// segment. The `(⚠ privilege)` warning is always kept. [width] `<= 0` (unknown,
/// or web clients) always renders the full form.
String formatShellPrompt({
  required String principal,
  required String node,
  required String cwd,
  String? branch,
  String? gitStatus,
  String? privilege,
  bool color = true,
  int width = 0,
}) {
  final hasCounts = gitStatus != null && gitStatus.isNotEmpty;
  final shortCwd = _shortCwd(cwd);
  final priv = privilege == null ? '' : ' (⚠ $privilege)';

  // Progressive levels, least → most aggressive: (showNode, useShortCwd,
  // showGit, showCounts). Widths are monotonically non-increasing, so a
  // first-fit scan finds the least-aggressive level that fits.
  const levels = [
    (true, false, true, true), // 0: full
    (true, false, true, false), // 1: drop git counts
    (false, false, true, false), // 2: drop @node
    (false, true, true, false), // 3: cwd → …/basename
    (false, true, false, false), // 4: drop git segment
  ];

  String plain(int level) {
    final (showNode, useShort, showGit, showCounts) = levels[level];
    final nodePart = showNode ? '@$node' : '';
    final cwdPart = useShort ? shortCwd : cwd;
    final counts = showCounts && hasCounts ? ' $gitStatus' : '';
    final git = branch == null || !showGit ? '' : ' git($branch$counts)';
    return '$principal$nodePart:$cwdPart$git$priv \$ ';
  }

  var level = 0;
  if (width > 0) {
    level = levels.length - 1; // fallback: nothing fits, use the most compact.
    for (var i = 0; i < levels.length; i++) {
      if (plain(i).runes.length + _typingRoom <= width) {
        level = i;
        break;
      }
    }
  }

  if (!color) return plain(level);

  const reset = '\u001b[0m';
  const red = '\u001b[31m';
  const boldRed = '\u001b[1;31m';
  const green = '\u001b[32m';
  const blue = '\u001b[34m';
  const cyan = '\u001b[36m';
  final (showNode, useShort, showGit, showCounts) = levels[level];
  final nodePart = showNode ? '@$node' : '';
  final cwdPart = useShort ? shortCwd : cwd;
  final counts = showCounts && hasCounts ? ' $gitStatus' : '';
  final coloredCounts = counts.isEmpty ? '' : '$green$counts$red';
  final git = branch == null || !showGit
      ? ''
      : ' ${blue}git($red$branch$coloredCounts$reset$blue)$reset';
  final coloredPriv = privilege == null ? '' : ' $boldRed(⚠ $privilege)$reset';
  return '$green$principal$nodePart$reset:$cyan$cwdPart$reset$git'
      '$coloredPriv \$ ';
}

/// Columns kept free for typing when choosing a prompt shrink level.
const int _typingRoom = 16;

/// Shortens [cwd] to `…/<last segment>` (both POSIX and Windows separators).
/// Returns [cwd] unchanged when it has no separator or is just a root.
String _shortCwd(String cwd) {
  final trimmed = cwd.replaceAll(RegExp(r'[/\\]+$'), '');
  final idx = trimmed.lastIndexOf(RegExp(r'[/\\]'));
  if (idx < 0) return cwd;
  final base = trimmed.substring(idx + 1);
  if (base.isEmpty) return cwd;
  return '…/$base';
}
