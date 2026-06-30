/// Integer rectangle geometry for TUI layout. All coordinates are 0-based cell
/// positions; [Rect] is half-open on the right/bottom (a width-`w` rect spans
/// columns `left .. left + w - 1`).
library;

/// An axis-aligned rectangle of terminal cells.
class Rect {
  const Rect(this.left, this.top, this.width, this.height);

  /// A zero-area rect, e.g. for an omitted pane.
  static const empty = Rect(0, 0, 0, 0);

  final int left;
  final int top;
  final int width;
  final int height;

  /// The exclusive right edge (`left + width`).
  int get right => left + width;

  /// The exclusive bottom edge (`top + height`).
  int get bottom => top + height;

  /// Whether the rect has no area.
  bool get isEmpty => width <= 0 || height <= 0;

  /// Whether cell (`x`,`y`) lies inside the rect.
  bool contains(int x, int y) =>
      x >= left && x < right && y >= top && y < bottom;

  /// A sub-rect inset by [dx] on the left/right and [dy] on the top/bottom,
  /// clamped to non-negative dimensions.
  Rect deflate(int dx, int dy) => Rect(
    left + dx,
    top + dy,
    (width - 2 * dx).clamp(0, width),
    (height - 2 * dy).clamp(0, height),
  );

  /// Splits the rect into a left column of width [w] and the remaining right
  /// column, returning `(left, right)`. [w] is clamped to `[0, width]`.
  (Rect, Rect) splitLeft(int w) {
    final lw = w.clamp(0, width);
    return (
      Rect(left, top, lw, height),
      Rect(left + lw, top, width - lw, height),
    );
  }

  /// Splits the rect into a top row of height [h] and the remaining bottom row,
  /// returning `(top, bottom)`. [h] is clamped to `[0, height]`.
  (Rect, Rect) splitTop(int h) {
    final th = h.clamp(0, height);
    return (
      Rect(left, top, width, th),
      Rect(left, top + th, width, height - th),
    );
  }

  /// Splits the rect into all rows except the last [h], and a bottom row of
  /// height [h], returning `(rest, bottom)`.
  (Rect, Rect) splitBottom(int h) => splitTop((height - h).clamp(0, height));

  @override
  bool operator ==(Object other) =>
      other is Rect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'Rect($left,$top,$width,$height)';
}
