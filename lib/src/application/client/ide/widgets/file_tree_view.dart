import '../git/git_status.dart';
import '../model/file_tree.dart';
import '../tui/geometry.dart';
import '../tui/screen_buffer.dart';
import '../tui/style.dart';
import 'palette.dart';

/// Paints the file-tree pane: one row per visible node, with an expand chevron
/// for directories, indentation by depth, and a colour drawn from the node's
/// git status. The selected row is highlighted (brighter when the pane has
/// focus). Pure rendering — all state (selection, scroll) is owned by the app.
class FileTreeView {
  /// Renders [nodes] (the flattened visible tree) into [rect], starting at
  /// [scrollTop], highlighting index [selected]. [statusOf] returns a node's git
  /// status by absolute path (or `null`).
  static void render(
    ScreenBuffer buf,
    Rect rect, {
    required List<FileNode> nodes,
    required int selected,
    required int scrollTop,
    required GitFileStatus? Function(String absPath) statusOf,
    required bool focused,
  }) {
    buf.fillRect(
      rect.left,
      rect.top,
      rect.width,
      rect.height,
      ' ',
      Palette.panelBg,
    );
    for (var row = 0; row < rect.height; row++) {
      final index = scrollTop + row;
      if (index < 0 || index >= nodes.length) break;
      final node = nodes[index];
      final y = rect.top + row;
      final isSelected = index == selected;
      final status = statusOf(node.path);

      var base = node.isDir ? Palette.treeDir : Palette.treeFile;
      final statusColor = _statusColor(status);
      if (statusColor != null) base = base.copyWith(fg: statusColor);
      if (isSelected) {
        base = focused
            ? Palette.treeSelectedActive
            : Palette.treeSelectedInactive.copyWith(
                fg: statusColor ?? Palette.treeSelectedInactive.fg,
              );
      }

      // Fill the whole row with the row background first.
      buf.fillRect(rect.left, y, rect.width, 1, ' ', base);

      final indent = node.depth; // one column per depth level
      final chevron = node.isDir ? (node.expanded ? '▾' : '▸') : ' ';
      final label = node.isDir ? '${node.name}/' : node.name;
      final tag = _statusTag(status);
      final text = '${' ' * indent}$chevron $label';
      var end = buf.drawText(
        rect.left + 1,
        y,
        text,
        base,
        maxWidth: rect.width - 2,
      );
      // A trailing one-letter git tag (M/A/D/?), right-aligned if room.
      if (tag != null && rect.width > text.length + 3) {
        final tagStyle = isSelected
            ? base
            : Palette.panelBg.copyWith(fg: statusColor);
        buf.drawText(rect.right - 2, y, tag, tagStyle);
      }
      if (end < rect.left) end = rect.left;
    }
  }

  static Color? _statusColor(GitFileStatus? status) {
    switch (status) {
      case GitFileStatus.modified:
      case GitFileStatus.renamed:
        return Palette.gitModified;
      case GitFileStatus.added:
        return Palette.gitAdded;
      case GitFileStatus.untracked:
        return Palette.gitUntracked;
      case GitFileStatus.deleted:
        return Palette.gitDeleted;
      case GitFileStatus.conflicted:
        return Palette.gitDeleted;
      case null:
      case GitFileStatus.clean:
      case GitFileStatus.ignored:
        return null;
    }
  }

  static String? _statusTag(GitFileStatus? status) {
    switch (status) {
      case GitFileStatus.modified:
        return 'M';
      case GitFileStatus.added:
        return 'A';
      case GitFileStatus.deleted:
        return 'D';
      case GitFileStatus.renamed:
        return 'R';
      case GitFileStatus.untracked:
        return '?';
      case GitFileStatus.conflicted:
        return '!';
      case null:
      case GitFileStatus.clean:
      case GitFileStatus.ignored:
        return null;
    }
  }
}
