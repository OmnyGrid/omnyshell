import 'highlighter.dart';

/// A no-op highlighter: every line is a single plain run. Used as the fallback
/// for file types without a dedicated highlighter.
class PlainHighlighter extends Highlighter {
  const PlainHighlighter([this.language = 'Text']);

  @override
  final String language;

  @override
  LineHighlight highlight(String line, HighlightState state, TokenTheme theme) {
    return LineHighlight([
      StyledRun(line, theme.styleFor(TokenType.plain)),
    ], HighlightState.none);
  }
}
