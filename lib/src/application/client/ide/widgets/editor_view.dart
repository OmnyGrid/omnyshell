import '../model/editor_tab.dart';
import '../git/git_status.dart';
import '../syntax/highlighter.dart';
import '../tui/geometry.dart';
import '../tui/screen_buffer.dart';
import '../tui/style.dart';
import 'palette.dart';

/// Paints an [EditorTab]'s text into the editor [rect]: a git-change gutter, a
/// right-aligned line-number column, and the syntax-highlighted source with
/// horizontal and vertical scrolling. Returns the on-screen cursor position when
/// [focused] (so the app can place the hardware caret), else `null`.
class EditorView {
  /// Renders [tab] into [rect] using [theme] for token colours.
  static ({int x, int y})? render(
    ScreenBuffer buf,
    Rect rect, {
    required EditorTab tab,
    required TokenTheme theme,
    required bool focused,
  }) {
    buf.fillRect(
      rect.left,
      rect.top,
      rect.width,
      rect.height,
      ' ',
      Palette.editorBg,
    );
    if (rect.isEmpty) return null;

    final doc = tab.document;
    if (doc.isBinary) {
      final msg = '— binary file (read-only) —';
      buf.drawText(
        rect.left + ((rect.width - msg.length) ~/ 2).clamp(0, rect.width),
        rect.top + rect.height ~/ 2,
        msg,
        Palette.editorBg.copyWith(fg: const Color.indexed(245)),
        maxWidth: rect.width,
      );
      return null;
    }

    final numberWidth = doc.lineCount.toString().length.clamp(2, 9);
    final gutterWidth = 1 + numberWidth + 1; // git mark + number + space
    final textLeft = rect.left + gutterWidth;
    final textWidth = rect.width - gutterWidth;
    if (textWidth <= 0) return null;

    _clampScroll(tab, rect, textWidth);

    for (var row = 0; row < rect.height; row++) {
      final lineIndex = tab.scrollTop + row;
      final y = rect.top + row;
      if (lineIndex >= doc.lineCount) {
        // Past end-of-file: a dim tilde marker, vim-style.
        buf.drawText(rect.left, y, '~', Palette.lineNumber);
        continue;
      }
      final isCursorLine = lineIndex == doc.cursorRow;
      final lineBg = isCursorLine ? Palette.currentLineBg : null;
      if (isCursorLine) {
        buf.fillRect(
          rect.left,
          y,
          rect.width,
          1,
          ' ',
          Palette.editorBg.copyWith(bg: lineBg),
        );
      }

      _drawGutter(buf, rect.left, y, lineIndex, numberWidth, tab, isCursorLine);
      _drawLine(buf, textLeft, y, textWidth, lineIndex, tab, theme, lineBg);
    }

    if (!focused) return null;
    final cy = rect.top + (doc.cursorRow - tab.scrollTop);
    final cx = textLeft + (doc.cursorCol - tab.scrollLeft);
    if (cy < rect.top ||
        cy >= rect.bottom ||
        cx < textLeft ||
        cx >= rect.right) {
      return null;
    }
    return (x: cx, y: cy);
  }

  static void _drawGutter(
    ScreenBuffer buf,
    int left,
    int y,
    int lineIndex,
    int numberWidth,
    EditorTab tab,
    bool isCursorLine,
  ) {
    final lineNo = lineIndex + 1;
    final mark = tab.gutter.marks[lineNo];
    final hasDeletion = tab.gutter.deletionsBefore.contains(lineNo);
    final markChar = mark == null && !hasDeletion
        ? ' '
        : (hasDeletion && mark == null ? '▁' : '▎');
    final markColor = switch (mark) {
      GutterMark.added => Palette.gitAdded,
      GutterMark.modified => Palette.gitModified,
      null => hasDeletion ? Palette.gitDeleted : null,
    };
    final numStyle = isCursorLine
        ? Palette.lineNumberCurrent
        : Palette.lineNumber;
    buf.setCell(
      left,
      y,
      markChar,
      numStyle.copyWith(fg: markColor ?? numStyle.fg),
    );
    final label = lineNo.toString().padLeft(numberWidth);
    buf.drawText(left + 1, y, label, numStyle);
    buf.setCell(left + 1 + numberWidth, y, ' ', numStyle);
  }

  static void _drawLine(
    ScreenBuffer buf,
    int textLeft,
    int y,
    int textWidth,
    int lineIndex,
    EditorTab tab,
    TokenTheme theme,
    Color? lineBg,
  ) {
    final hl = tab.highlightLine(lineIndex, theme);
    final right = textLeft + textWidth;
    var lineCol = 0; // character index within the source line
    for (final run in hl.runs) {
      final style = lineBg == null ? run.style : run.style.copyWith(bg: lineBg);
      for (final rune in run.text.runes) {
        final screenX = textLeft + (lineCol - tab.scrollLeft);
        if (screenX >= textLeft && screenX < right) {
          final ch = rune == 0x09 ? ' ' : String.fromCharCode(rune);
          buf.setCell(screenX, y, ch, style);
        }
        lineCol++;
        if (screenX >= right) break;
      }
    }
  }

  /// Keeps the cursor inside the viewport by adjusting the tab's scroll offsets.
  static void _clampScroll(EditorTab tab, Rect rect, int textWidth) {
    final doc = tab.document;
    if (doc.cursorRow < tab.scrollTop) {
      tab.scrollTop = doc.cursorRow;
    } else if (doc.cursorRow >= tab.scrollTop + rect.height) {
      tab.scrollTop = doc.cursorRow - rect.height + 1;
    }
    if (tab.scrollTop < 0) tab.scrollTop = 0;

    if (doc.cursorCol < tab.scrollLeft) {
      tab.scrollLeft = doc.cursorCol;
    } else if (doc.cursorCol >= tab.scrollLeft + textWidth) {
      tab.scrollLeft = doc.cursorCol - textWidth + 1;
    }
    if (tab.scrollLeft < 0) tab.scrollLeft = 0;
  }
}
