import '../tui/geometry.dart';
import '../tui/screen_buffer.dart';
import 'palette.dart';

/// Paints the bottom status bar: the file path and modified/read-only flags on
/// the left, and the language, git branch and caret position on the right. A
/// transient [message] (e.g. "Saved", or an error) takes over the bar when set.
class StatusBar {
  static void render(
    ScreenBuffer buf,
    Rect rect, {
    required String path,
    required bool dirty,
    required bool readOnly,
    required int line,
    required int column,
    required String language,
    String? branch,
    String? message,
    bool messageIsError = false,
  }) {
    if (rect.isEmpty) return;
    final y = rect.top;

    if (message != null) {
      final style = messageIsError
          ? Palette.statusError
          : Palette.statusMessage;
      buf.fillRect(rect.left, y, rect.width, 1, ' ', style);
      buf.drawText(rect.left + 1, y, message, style, maxWidth: rect.width - 2);
      return;
    }

    buf.fillRect(rect.left, y, rect.width, 1, ' ', Palette.statusBar);

    final left =
        '${dirty ? '● ' : ''}${path.isEmpty ? 'untitled' : path}'
        '${readOnly ? '  [read-only]' : ''}';
    buf.drawText(
      rect.left + 1,
      y,
      left,
      Palette.statusBar,
      maxWidth: rect.width - 2,
    );

    final right = [
      if (branch != null && branch.isNotEmpty) '⎇ $branch',
      language,
      'Ln $line, Col $column',
    ].join('   ');
    final rx = rect.right - 1 - right.length;
    if (rx > rect.left + left.length + 1) {
      buf.drawText(rx, y, right, Palette.statusBar);
    }
  }
}
