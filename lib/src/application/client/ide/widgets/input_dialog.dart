import '../tui/geometry.dart';
import '../tui/screen_buffer.dart';
import 'palette.dart';

/// Paints a small centred modal prompt — a bordered box with a [title], the
/// current [value] being typed, and an optional [hint] line — over the editor.
/// Used by the `Ctrl-L` "go to line" prompt.
///
/// Returns the cell where the caret should sit (the end of [value]), so the
/// caller can place the hardware cursor there.
class InputDialog {
  static ({int x, int y}) render(
    ScreenBuffer buf,
    Rect area, {
    required String title,
    required String value,
    String? hint,
  }) {
    final hasHint = hint != null && hint.isNotEmpty;

    // Inner content width: wide enough for the title, value or hint, clamped to
    // what the screen can hold.
    final maxInner = (area.width - 4).clamp(4, area.width);
    var inner = 24;
    for (final w in [title.length + 2, value.length + 1, hint?.length ?? 0]) {
      if (w > inner) inner = w;
    }
    if (inner > maxInner) inner = maxInner;

    final boxW = inner + 4; // 2 borders + 2 padding columns
    final boxH = hasHint ? 4 : 3; // top border, input, [hint], bottom border
    final left = area.left + ((area.width - boxW) ~/ 2).clamp(0, area.width);
    final top = area.top + ((area.height - boxH) ~/ 2).clamp(0, area.height);

    final bg = Palette.dialogBg;
    final border = Palette.dialogBorder;

    // Background fill.
    for (var y = 0; y < boxH; y++) {
      buf.fillRect(left, top + y, boxW, 1, ' ', bg);
    }
    // Border frame.
    buf.setCell(left, top, '┌', border);
    buf.setCell(left + boxW - 1, top, '┐', border);
    buf.setCell(left, top + boxH - 1, '└', border);
    buf.setCell(left + boxW - 1, top + boxH - 1, '┘', border);
    for (var x = 1; x < boxW - 1; x++) {
      buf.setCell(left + x, top, '─', border);
      buf.setCell(left + x, top + boxH - 1, '─', border);
    }
    for (var y = 1; y < boxH - 1; y++) {
      buf.setCell(left, top + y, '│', border);
      buf.setCell(left + boxW - 1, top + y, '│', border);
    }

    // Title sits on the top border.
    buf.drawText(
      left + 2,
      top,
      ' $title ',
      Palette.dialogTitle,
      maxWidth: boxW - 4,
    );

    // Input value.
    final contentX = left + 2;
    final inputY = top + 1;
    buf.drawText(contentX, inputY, value, bg, maxWidth: inner);
    final caretX = (contentX + value.length).clamp(contentX, left + boxW - 2);

    if (hasHint) {
      buf.drawText(
        contentX,
        top + 2,
        hint,
        Palette.dialogHint,
        maxWidth: inner,
      );
    }

    return (x: caretX, y: inputY);
  }
}
