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

    final (:labels, :starts, :offset) = _layout(rect, tabs, active);
    for (var i = 0; i < tabs.length; i++) {
      final style = i == active ? Palette.tabActive : Palette.tabInactive;
      final col = rect.left + starts[i] - offset;
      if (col + labels[i].length < rect.left || col > rect.right) continue;
      buf.drawText(col, rect.top, labels[i], style, maxWidth: rect.right - col);
    }
  }

  /// The index of the tab drawn at screen column [x] of the bar in [rect]
  /// (laid out exactly as [render] does), or `null` past the last label.
  static int? tabAt(
    Rect rect, {
    required List<EditorTab> tabs,
    required int active,
    required int x,
  }) {
    if (tabs.isEmpty || x < rect.left || x >= rect.right) return null;
    final (:labels, :starts, :offset) = _layout(rect, tabs, active);
    final col = x - rect.left + offset; // position along the unscrolled row
    for (var i = 0; i < tabs.length; i++) {
      if (col >= starts[i] && col < starts[i] + labels[i].length) return i;
    }
    return null;
  }

  /// Each tab's label, its start along the unscrolled row, and the horizontal
  /// [offset] that keeps the [active] tab in view. Shared by [render] and
  /// [tabAt] so a click always hits the label that is drawn there.
  static ({List<String> labels, List<int> starts, int offset}) _layout(
    Rect rect,
    List<EditorTab> tabs,
    int active,
  ) {
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
    return (labels: labels, starts: starts, offset: offset);
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
