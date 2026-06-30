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
String formatShellPrompt({
  required String principal,
  required String node,
  required String cwd,
  String? branch,
  String? gitStatus,
  String? privilege,
  bool color = true,
}) {
  final counts = gitStatus != null && gitStatus.isNotEmpty ? ' $gitStatus' : '';
  if (!color) {
    final git = branch == null ? '' : ' git($branch$counts)';
    final priv = privilege == null ? '' : ' (⚠ $privilege)';
    return '$principal@$node:$cwd$git$priv \$ ';
  }
  const reset = '\u001b[0m';
  const red = '\u001b[31m';
  const boldRed = '\u001b[1;31m';
  const green = '\u001b[32m';
  const blue = '\u001b[34m';
  const cyan = '\u001b[36m';
  final coloredCounts = counts.isEmpty ? '' : '$green$counts$red';
  final git = branch == null
      ? ''
      : ' ${blue}git($red$branch$coloredCounts$reset$blue)$reset';
  final priv = privilege == null ? '' : ' $boldRed(⚠ $privilege)$reset';
  return '$green$principal@$node$reset:$cyan$cwd$reset$git$priv \$ ';
}
