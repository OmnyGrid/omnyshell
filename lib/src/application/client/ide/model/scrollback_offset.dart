import '../tui/key.dart';

/// The scroll position of a bottom-anchored output pane (the IDE's terminal
/// and AI agent panels): how many lines the view is scrolled up from the
/// newest output, 0 meaning "following the bottom".
///
/// Both panels share these rules, so they live here once: PgUp/PgDn move a
/// page of [pageLines], Home/End jump to the top/bottom, the mouse wheel moves
/// by [scrollLines], and the view clamps the offset with [clampScroll] on each
/// render (the mixin cannot know the top, which depends on the output length
/// and the pane's size and wrap width).
mixin ScrollbackOffset {
  /// Lines moved by PgUp/PgDn.
  static const pageLines = 5;

  /// Stands in for "the top" until the next render clamps it, for Home.
  static const _top = 1 << 30;

  int _scrollOffset = 0;

  /// How many lines the view is scrolled up from the bottom (0 = bottom).
  int get scroll => _scrollOffset;

  /// Scrolls by [lines] (positive = up, toward older output), e.g. for the
  /// mouse wheel. Never below 0; the top is applied by [clampScroll].
  void scrollLines(int lines) =>
      _scrollOffset = (_scrollOffset + lines).clamp(0, _top);

  /// Returns to the newest output (after typing or submitting input).
  void scrollToBottom() => _scrollOffset = 0;

  /// Clamps the stored offset to [max] (the most the view can scroll up at its
  /// current size) and returns it. The view calls it on every render so the
  /// stored offset never runs past the top: otherwise a burst of wheel steps
  /// (or Home's sentinel) would leave it far above, and scrolling back down
  /// would do nothing visible until it had unwound.
  int clampScroll(int max) => _scrollOffset = _scrollOffset.clamp(0, max);

  /// Applies PgUp/PgDn/Home/End to the offset. Returns whether [key] was one
  /// of them, so a panel's key handler can try it for keys it does not own.
  bool handleScrollKey(KeyEvent key) {
    switch (key.type) {
      case KeyType.pageUp:
        scrollLines(pageLines);
      case KeyType.pageDown:
        scrollLines(-pageLines);
      case KeyType.home:
        _scrollOffset = _top;
      case KeyType.end:
        scrollToBottom();
      default:
        return false;
    }
    return true;
  }
}
