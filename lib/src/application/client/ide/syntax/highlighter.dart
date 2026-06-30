import '../tui/style.dart';

/// A semantic token category. The [TokenTheme] maps each category to a concrete
/// [Style], so the colour scheme is defined in one place and every language
/// highlighter speaks in these neutral terms.
enum TokenType {
  plain,
  keyword,
  type,
  string,
  number,
  comment,
  operatorTok,
  punctuation,
  function,
  property,
  constant,
  attribute,
  tag,
  escape,
  heading,
  emphasis,
  strong,
  link,
  codeSpan,
  listMarker,
  blockquote,
}

/// A contiguous run of text rendered in a single [Style].
class StyledRun {
  const StyledRun(this.text, this.style);
  final String text;
  final Style style;

  @override
  bool operator ==(Object other) =>
      other is StyledRun && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => 'StyledRun(${_short(text)})';
  static String _short(String s) =>
      s.length > 12 ? '${s.substring(0, 12)}…' : s;
}

/// Opaque per-line carry state for multi-line constructs (block comments,
/// triple-quoted strings, fenced code blocks). Each highlighter assigns its own
/// meaning to [mode]; `0` ([none]) is always "no carry / start of file".
class HighlightState {
  const HighlightState(this.mode);
  final int mode;

  static const none = HighlightState(0);

  @override
  bool operator ==(Object other) =>
      other is HighlightState && other.mode == mode;

  @override
  int get hashCode => mode;
}

/// The result of highlighting one line: the styled [runs] (in order, covering
/// the whole line) and the [next] carry state for the following line.
class LineHighlight {
  const LineHighlight(this.runs, this.next);
  final List<StyledRun> runs;
  final HighlightState next;

  /// The concatenated plain text of all runs (handy in tests).
  String get text => runs.map((r) => r.text).join();
}

/// Maps [TokenType]s to terminal [Style]s — the IDE's colour scheme. A single
/// dark theme is provided as [TokenTheme.dark]; it uses 256-colour indices so
/// it looks consistent across terminals.
class TokenTheme {
  const TokenTheme(this._styles);

  final Map<TokenType, Style> _styles;

  /// The style for [type], falling back to the plain style.
  Style styleFor(TokenType type) =>
      _styles[type] ?? _styles[TokenType.plain] ?? Style.none;

  /// A balanced dark theme.
  static const dark = TokenTheme({
    TokenType.plain: Style(fg: Color.indexed(252)),
    TokenType.keyword: Style(fg: Color.indexed(204), bold: true),
    TokenType.type: Style(fg: Color.indexed(81)),
    TokenType.string: Style(fg: Color.indexed(114)),
    TokenType.number: Style(fg: Color.indexed(215)),
    TokenType.comment: Style(fg: Color.indexed(245), italic: true),
    TokenType.operatorTok: Style(fg: Color.indexed(204)),
    TokenType.punctuation: Style(fg: Color.indexed(250)),
    TokenType.function: Style(fg: Color.indexed(149)),
    TokenType.property: Style(fg: Color.indexed(117)),
    TokenType.constant: Style(fg: Color.indexed(215)),
    TokenType.attribute: Style(fg: Color.indexed(117)),
    TokenType.tag: Style(fg: Color.indexed(204)),
    TokenType.escape: Style(fg: Color.indexed(215), bold: true),
    TokenType.heading: Style(fg: Color.indexed(39), bold: true),
    TokenType.emphasis: Style(fg: Color.indexed(252), italic: true),
    TokenType.strong: Style(fg: Color.indexed(252), bold: true),
    TokenType.link: Style(fg: Color.indexed(39), underline: true),
    TokenType.codeSpan: Style(fg: Color.indexed(114)),
    TokenType.listMarker: Style(fg: Color.indexed(215), bold: true),
    TokenType.blockquote: Style(fg: Color.indexed(245), italic: true),
  });
}

/// Highlights source text one line at a time, threading a [HighlightState] so
/// multi-line constructs survive line boundaries.
///
/// Implementations must be pure (no IO) and deterministic, so they can be unit
/// tested directly on strings.
abstract class Highlighter {
  const Highlighter();

  /// The language name (for the status bar), e.g. `'Dart'`.
  String get language;

  /// The carry state at the top of a file.
  HighlightState get initial => HighlightState.none;

  /// Highlights [line] given the [state] left by the previous line.
  LineHighlight highlight(String line, HighlightState state, TokenTheme theme);
}
