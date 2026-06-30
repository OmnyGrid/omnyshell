import '../terminal/terminal_panel.dart';
import '../tui/geometry.dart';
import '../tui/screen_buffer.dart';
import 'palette.dart';

/// Renders the integrated terminal panel into [rect]: a title bar (with the
/// working directory), a scrollback output area, and the input line at the
/// bottom. Returns the caret position on the input line when [focused], so the
/// caller can place the hardware cursor (null otherwise).
class TerminalView {
  static ({int x, int y})? render(
    ScreenBuffer buf,
    Rect rect, {
    required TerminalPanel panel,
    required bool focused,
  }) {
    if (rect.isEmpty || rect.height < 3) return null;

    // Title bar.
    final titleY = rect.top;
    final titleStyle = focused ? Palette.tabActive : Palette.tabBarBg;
    buf.fillRect(rect.left, titleY, rect.width, 1, ' ', Palette.tabBarBg);
    buf.drawText(
      rect.left + 1,
      titleY,
      ' TERMINAL ',
      titleStyle,
      maxWidth: rect.width - 2,
    );
    // Working directory, right-aligned (tail kept when too long).
    final cwd = panel.cwd;
    final cwdX = rect.right - 1 - cwd.length;
    if (cwdX > rect.left + 12) {
      buf.drawText(cwdX, titleY, cwd, Palette.tabInactive);
    } else if (rect.width > 16) {
      final keep = rect.width - 16;
      final tail = cwd.length > keep
          ? '…${cwd.substring(cwd.length - keep)}'
          : cwd;
      buf.drawText(
        rect.right - 1 - tail.length,
        titleY,
        tail,
        Palette.tabInactive,
      );
    }

    // Output area sits between the title bar and the input line.
    final outTop = rect.top + 1;
    final outHeight = rect.height - 2;
    final lines = panel.lines;
    final maxScroll = (lines.length - outHeight).clamp(0, lines.length);
    final scroll = panel.scroll.clamp(0, maxScroll);
    final firstLine = (lines.length - outHeight - scroll).clamp(
      0,
      lines.length,
    );
    for (var i = 0; i < outHeight; i++) {
      final idx = firstLine + i;
      if (idx < 0 || idx >= lines.length) continue;
      buf.drawText(
        rect.left + 1,
        outTop + i,
        lines[idx],
        Palette.editorBg,
        maxWidth: rect.width - 2,
      );
    }

    // Input line.
    final inputY = rect.top + rect.height - 1;
    final prompt = panel.isRunning ? '⋯ ' : '\$ ';
    final promptStyle = focused
        ? Palette.lineNumberCurrent
        : Palette.lineNumber;
    buf.fillRect(rect.left, inputY, rect.width, 1, ' ', promptStyle);
    buf.drawText(
      rect.left + 1,
      inputY,
      '$prompt${panel.input}',
      promptStyle,
      maxWidth: rect.width - 2,
    );

    if (!focused) return null;
    final caretX = (rect.left + 1 + prompt.length + panel.input.length).clamp(
      rect.left + 1,
      rect.right - 1,
    );
    return (x: caretX, y: inputY);
  }
}
