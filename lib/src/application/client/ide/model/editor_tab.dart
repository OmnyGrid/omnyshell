import '../git/git_status.dart';
import '../syntax/highlighter.dart';
import '../syntax/highlighter_registry.dart';
import 'text_document.dart';

/// One open file in the editor: its [document], the [highlighter] chosen from
/// the file's extension, the per-line git [gutter], the viewport scroll offsets,
/// and a cache of per-line highlight start-states so a line can be highlighted
/// without re-scanning the whole file each frame.
class EditorTab {
  EditorTab(this.document, {required this.highlighter, LineGutter? gutter})
    : gutter = gutter ?? LineGutter.empty;

  /// Builds a tab for [path] from its already-read [content], picking a
  /// highlighter from [registry] (or a fresh default registry) by extension.
  factory EditorTab.fromContent(
    String path,
    String content, {
    HighlighterRegistry? registry,
    LineGutter? gutter,
  }) {
    final reg = registry ?? HighlighterRegistry();
    return EditorTab(
      TextDocument.fromContent(path, content),
      highlighter: reg.forPath(path),
      gutter: gutter,
    );
  }

  final TextDocument document;
  final Highlighter highlighter;

  /// Per-line git change marks; refreshed by the controller after edits/saves.
  LineGutter gutter;

  /// First visible buffer line (vertical scroll).
  int scrollTop = 0;

  /// First visible column (horizontal scroll).
  int scrollLeft = 0;

  /// Cache of the highlighter carry-state at the start of each line; index `r`
  /// is the state entering line `r`. Rebuilt lazily by [stateBefore].
  List<HighlightState>? _startStates;

  /// The file's display path.
  String get path => document.path;

  /// Invalidate the highlight-state cache (call after any edit).
  void invalidateHighlight() => _startStates = null;

  /// The carry state entering line [row], computing and caching the prefix as
  /// needed.
  HighlightState stateBefore(int row, TokenTheme theme) {
    final states = _ensureStates(theme, upTo: row);
    if (row <= 0) return highlighter.initial;
    return row < states.length ? states[row] : highlighter.initial;
  }

  /// Highlights line [row] using the cached start-state.
  LineHighlight highlightLine(int row, TokenTheme theme) {
    final state = stateBefore(row, theme);
    return highlighter.highlight(document.lineAt(row), state, theme);
  }

  List<HighlightState> _ensureStates(TokenTheme theme, {required int upTo}) {
    final cache = _startStates;
    if (cache != null && cache.length > upTo) return cache;
    // (Re)build from the start; cheap for the files the IDE edits and only done
    // when the cache is cold or too short.
    final states = <HighlightState>[highlighter.initial];
    var state = highlighter.initial;
    final limit = document.lineCount;
    for (var r = 0; r < limit; r++) {
      state = highlighter.highlight(document.lineAt(r), state, theme).next;
      states.add(state);
    }
    _startStates = states;
    return states;
  }
}
