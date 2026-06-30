import '../agent/agent_panel.dart';
import '../tui/geometry.dart';
import '../tui/screen_buffer.dart';
import 'palette.dart';

/// Renders the AI agent panel into [rect]: a title bar (with the working
/// context), a word-wrapped conversation area, and the prompt input line.
/// Returns the caret position when [focused] (null otherwise).
class AgentView {
  static ({int x, int y})? render(
    ScreenBuffer buf,
    Rect rect, {
    required AgentPanel panel,
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
      ' AI AGENT ',
      titleStyle,
      maxWidth: rect.width - 2,
    );
    final ctx = panel.contextLabel;
    if (rect.width > 18) {
      final keep = rect.width - 14;
      final tail = ctx.length > keep
          ? '…${ctx.substring(ctx.length - keep)}'
          : ctx;
      buf.drawText(
        rect.right - 1 - tail.length,
        titleY,
        tail,
        Palette.tabInactive,
      );
    }

    // Conversation area (word-wrapped) between the title and the input line.
    final outTop = rect.top + 1;
    final outHeight = rect.height - 2;
    final width = rect.width - 2;
    final wrapped = <String>[];
    for (final line in panel.lines) {
      wrapped.addAll(_wrap(line, width));
    }
    final maxScroll = (wrapped.length - outHeight).clamp(0, wrapped.length);
    final scroll = panel.scroll.clamp(0, maxScroll);
    final firstLine = (wrapped.length - outHeight - scroll).clamp(
      0,
      wrapped.length,
    );
    for (var i = 0; i < outHeight; i++) {
      final idx = firstLine + i;
      if (idx < 0 || idx >= wrapped.length) continue;
      buf.drawText(
        rect.left + 1,
        outTop + i,
        wrapped[idx],
        Palette.editorBg,
        maxWidth: width,
      );
    }

    // Prompt input line.
    final inputY = rect.top + rect.height - 1;
    final prompt = panel.isBusy ? '⋯ ' : '› ';
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

  /// Greedily word-wraps [text] to [width] columns. A blank line stays blank;
  /// a word longer than [width] is hard-split.
  static List<String> _wrap(String text, int width) {
    if (width <= 0) return const [''];
    if (text.isEmpty) return const [''];
    final out = <String>[];
    var line = '';
    for (final word in text.split(' ')) {
      var w = word;
      // Hard-split a word that cannot fit on its own line.
      while (w.length > width) {
        if (line.isNotEmpty) {
          out.add(line);
          line = '';
        }
        out.add(w.substring(0, width));
        w = w.substring(width);
      }
      if (line.isEmpty) {
        line = w;
      } else if (line.length + 1 + w.length <= width) {
        line = '$line $w';
      } else {
        out.add(line);
        line = w;
      }
    }
    out.add(line);
    return out;
  }
}
