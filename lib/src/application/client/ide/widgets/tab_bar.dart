import '../model/editor_tab.dart';
import '../tui/geometry.dart';
import '../tui/screen_buffer.dart';
import 'palette.dart';

/// Paints the row of open-file tabs above the editor. The active tab is
/// highlighted; a modified buffer shows a `●` dot. Tabs scroll horizontally so
/// the active one stays visible when there are more tabs than fit.
class TabBar {
  /// Renders [tabs] into the single-row [rect], marking [active] and scrolling
  /// so the active tab is visible.
  static void render(
    ScreenBuffer buf,
    Rect rect, {
    required List<EditorTab> tabs,
    required int active,
  }) {
    buf.fillRect(rect.left, rect.top, rect.width, 1, ' ', Palette.tabBarBg);
    if (tabs.isEmpty) {
      buf.drawText(
        rect.left + 1,
        rect.top,
        'no files open — Tab to focus the tree, Enter to open',
        Palette.tabBarBg,
        maxWidth: rect.width - 2,
      );
      return;
    }

    // Build the label for each tab and find where the active one starts so we
    // can scroll it into view.
    final labels = [for (final t in tabs) _label(t)];
    final starts = <int>[];
    var x = 0;
    for (final l in labels) {
      starts.add(x);
      x += l.length;
    }
    final total = x;
    var offset = 0;
    if (total > rect.width) {
      final activeStart = starts[active];
      final activeEnd = activeStart + labels[active].length;
      if (activeEnd - offset > rect.width) {
        offset = activeEnd - rect.width;
      }
      if (activeStart < offset) offset = activeStart;
    }

    for (var i = 0; i < tabs.length; i++) {
      final style = i == active ? Palette.tabActive : Palette.tabInactive;
      final col = rect.left + starts[i] - offset;
      if (col + labels[i].length < rect.left || col > rect.right) continue;
      buf.drawText(col, rect.top, labels[i], style, maxWidth: rect.right - col);
    }
  }

  static String _label(EditorTab t) {
    final name = _basename(t.path);
    final dirty = t.document.dirty ? '●' : ' ';
    return ' $name $dirty ';
  }

  static String _basename(String path) {
    if (path.isEmpty) return 'untitled';
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }
}
