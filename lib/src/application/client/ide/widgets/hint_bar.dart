import '../tui/geometry.dart';
import '../tui/screen_buffer.dart';
import 'palette.dart';

/// Paints the persistent shortcut strip just above the status bar, e.g.
///
///     ^Q quit   ^S save   ^W close   ^B/Tab focus   ^N/^P tabs   Enter open
///
/// Each binding is a key (highlighted) followed by a dim label. The strip is
/// always visible while editing so the shortcuts are discoverable without the
/// welcome screen. When the tree is focused, the tree-only keys (`.`/`n`/`N`)
/// are shown first via [treeFocused], since they have no `Ctrl-` form and would
/// otherwise be undiscoverable once a file is open. Bindings are dropped from
/// the right when the terminal is too narrow to fit them all.
class HintBar {
  /// One key + label pair, e.g. `('^Q', 'quit')`.
  static const _global = <(String, String)>[
    ('^Q', 'quit'),
    ('^S', 'save'),
    ('^F', 'find'),
    ('^L', 'line'),
    ('^T', 'term'),
    ('^A', 'AI'),
    ('^W', 'close'),
    ('^B/Tab', 'focus'),
    ('^N/^P', 'tabs'),
    ('Enter', 'open'),
  ];

  /// Tree-panel keys, shown first when the tree is focused.
  static const _tree = <(String, String)>[
    ('n', 'new file'),
    ('N', 'new folder'),
    ('.', 'hidden'),
  ];

  static void render(ScreenBuffer buf, Rect rect, {bool treeFocused = false}) {
    if (rect.isEmpty) return;
    final y = rect.top;
    buf.fillRect(rect.left, y, rect.width, 1, ' ', Palette.hintBar);

    final hints = treeFocused ? [..._tree, ..._global] : _global;
    var x = rect.left + 1;
    final limit = rect.right - 1;
    for (final (key, label) in hints) {
      // Stop before a binding that would overflow, so we never draw a partial
      // one (1 leading gap + key + 1 space + label).
      final needed = key.length + 1 + label.length;
      if (x > rect.left + 1 && x + needed > limit) break;
      x = buf.drawText(x, y, key, Palette.hintKey, maxWidth: limit - x);
      x = buf.drawText(x, y, ' $label', Palette.hintBar, maxWidth: limit - x);
      x += 3; // gap before the next binding
    }
  }
}
