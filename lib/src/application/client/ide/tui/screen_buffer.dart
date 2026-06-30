import 'style.dart';

/// A single terminal cell: one printable character and its [Style].
///
/// The renderer compares cells by value, so changing only the style of a cell
/// repaints just that cell.
class Cell {
  const Cell(this.char, this.style);

  /// A blank space in the default style.
  static const blank = Cell(' ', Style.none);

  final String char;
  final Style style;

  @override
  bool operator ==(Object other) =>
      other is Cell && other.char == char && other.style == style;

  @override
  int get hashCode => Object.hash(char, style);
}

/// An off-screen grid of [Cell]s the widgets paint into, plus a diff-based
/// [renderDiff] that emits the minimal ANSI to turn a previous frame into this
/// one (so only changed cells are rewritten — no flicker, minimal bytes).
///
/// The buffer is terminal-agnostic: it produces a string of escape sequences
/// and never touches IO. The owning app holds the "front" buffer (the last
/// frame shown) and feeds it to [renderDiff].
class ScreenBuffer {
  ScreenBuffer(this.width, this.height)
    : _cells = List<Cell>.filled(
        (width < 0 ? 0 : width) * (height < 0 ? 0 : height),
        Cell.blank,
      );

  final int width;
  final int height;
  final List<Cell> _cells;

  int _index(int x, int y) => y * width + x;

  /// The cell at (`x`,`y`), or [Cell.blank] when out of bounds.
  Cell cellAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) return Cell.blank;
    return _cells[_index(x, y)];
  }

  /// Resets every cell to a blank in [style].
  void clear([Style style = Style.none]) {
    final blank = style == Style.none ? Cell.blank : Cell(' ', style);
    for (var i = 0; i < _cells.length; i++) {
      _cells[i] = blank;
    }
  }

  /// Paints a single character at (`x`,`y`); out-of-bounds writes are ignored.
  /// A multi-rune [char] is truncated to its first rune; an empty string paints
  /// a space.
  void setCell(int x, int y, String char, Style style) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    final runes = char.runes;
    final c = runes.isEmpty ? ' ' : String.fromCharCode(runes.first);
    _cells[_index(x, y)] = Cell(c, style);
  }

  /// Fills [rect]'s area (clipped to the buffer) with [char] in [style].
  void fillRect(int left, int top, int w, int h, String char, Style style) {
    for (var y = top; y < top + h; y++) {
      for (var x = left; x < left + w; x++) {
        setCell(x, y, char, style);
      }
    }
  }

  /// Draws [text] starting at (`x`,`y`), one cell per rune, clipped to the row
  /// and to [maxWidth] columns (when given). Tabs expand to a single space.
  /// Returns the column just past the last painted cell.
  int drawText(int x, int y, String text, Style style, {int? maxWidth}) {
    if (y < 0 || y >= height) return x;
    final limit = maxWidth == null ? width : (x + maxWidth).clamp(0, width);
    var col = x;
    for (final rune in text.runes) {
      if (col >= limit || col >= width) break;
      if (col >= 0) {
        final ch = rune == 0x09 ? ' ' : String.fromCharCode(rune);
        _cells[_index(col, y)] = Cell(ch, style);
      }
      col++;
    }
    return col;
  }

  /// Emits the ANSI needed to turn [previous] into this frame, rewriting only
  /// the cells that changed. When [previous] is `null` (or a different size) the
  /// whole frame is drawn.
  ///
  /// The returned string positions the cursor as needed and ends with an SGR
  /// reset; the caller is responsible for any final cursor placement.
  String renderDiff(ScreenBuffer? previous) {
    final reusable =
        previous != null &&
        previous.width == width &&
        previous.height == height;
    final out = StringBuffer();
    Style? current; // the SGR currently active in `out`.

    for (var y = 0; y < height; y++) {
      var x = 0;
      while (x < width) {
        final cell = _cells[_index(x, y)];
        final unchanged = reusable && previous._cells[_index(x, y)] == cell;
        if (unchanged) {
          x++;
          continue;
        }
        // Start of a changed run: move the cursor here (1-based) and paint
        // until the cells match `previous` again (or the row ends).
        out.write('\x1b[${y + 1};${x + 1}H');
        while (x < width) {
          final c = _cells[_index(x, y)];
          if (reusable && previous._cells[_index(x, y)] == c) break;
          if (current != c.style) {
            out.write(c.style.sgr);
            current = c.style;
          }
          out.write(c.char);
          x++;
        }
      }
    }
    if (current != null) out.write('\x1b[0m');
    return out.toString();
  }
}
