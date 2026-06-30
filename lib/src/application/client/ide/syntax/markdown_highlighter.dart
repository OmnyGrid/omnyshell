import 'highlighter.dart';
import 'scan_utils.dart';

/// A Markdown highlighter: ATX headings, blockquotes, list markers, thematic
/// breaks, fenced code blocks (carried across lines), and inline emphasis,
/// strong, code spans and links.
///
/// [HighlightState.mode] `1` means "inside a ``` fenced code block".
class MarkdownHighlighter extends Highlighter {
  const MarkdownHighlighter();

  @override
  String get language => 'Markdown';

  static const _inFence = 1;

  @override
  LineHighlight highlight(String line, HighlightState state, TokenTheme theme) {
    final b = RunBuilder(theme);
    final s = line;
    final trimmed = s.trimLeft();

    // Fenced code blocks.
    final isFence = trimmed.startsWith('```') || trimmed.startsWith('~~~');
    if (state.mode == _inFence) {
      b.add(s, isFence ? TokenType.punctuation : TokenType.codeSpan);
      return LineHighlight(
        b.build(),
        isFence ? HighlightState.none : const HighlightState(_inFence),
      );
    }
    if (isFence) {
      b.add(s, TokenType.punctuation);
      return LineHighlight(b.build(), const HighlightState(_inFence));
    }

    final indent = s.length - trimmed.length;
    b.add(s.substring(0, indent), TokenType.plain);

    // Thematic break.
    if (_isThematicBreak(trimmed)) {
      b.add(trimmed, TokenType.listMarker);
      return LineHighlight(b.build(), HighlightState.none);
    }

    // Heading.
    if (trimmed.startsWith('#')) {
      b.add(trimmed, TokenType.heading);
      return LineHighlight(b.build(), HighlightState.none);
    }

    // Blockquote.
    if (trimmed.startsWith('>')) {
      b.add(trimmed, TokenType.blockquote);
      return LineHighlight(b.build(), HighlightState.none);
    }

    var rest = trimmed;

    // List marker (-, *, +, or "N.").
    final marker = _listMarker(rest);
    if (marker > 0) {
      b.add(rest.substring(0, marker), TokenType.listMarker);
      rest = rest.substring(marker);
    }

    _inline(b, rest, theme);
    return LineHighlight(b.build(), HighlightState.none);
  }

  bool _isThematicBreak(String t) {
    if (t.length < 3) return false;
    final c = t.codeUnitAt(0);
    if (c != 0x2d && c != 0x2a && c != 0x5f) return false;
    for (var i = 0; i < t.length; i++) {
      final d = t.codeUnitAt(i);
      if (d != c && !isSpace(d)) return false;
    }
    return true;
  }

  /// Returns the length of a leading list marker (including its trailing
  /// space), or 0 if [t] does not start with one.
  int _listMarker(String t) {
    if (t.length >= 2) {
      final c = t.codeUnitAt(0);
      if ((c == 0x2d || c == 0x2a || c == 0x2b) && t.codeUnitAt(1) == 0x20) {
        return 2;
      }
    }
    // Ordered: digits then '.' or ')' then space.
    var i = 0;
    while (i < t.length && isDigit(t.codeUnitAt(i))) {
      i++;
    }
    if (i > 0 &&
        i + 1 < t.length &&
        (t.codeUnitAt(i) == 0x2e || t.codeUnitAt(i) == 0x29) &&
        t.codeUnitAt(i + 1) == 0x20) {
      return i + 2;
    }
    return 0;
  }

  /// Highlights inline spans (code, strong, emphasis, links) in [text].
  void _inline(RunBuilder b, String text, TokenTheme theme) {
    final n = text.length;
    var i = 0;
    while (i < n) {
      final c = text.codeUnitAt(i);
      // Inline code span: `...`.
      if (c == 0x60) {
        final end = text.indexOf('`', i + 1);
        if (end > i) {
          b.add(text.substring(i, end + 1), TokenType.codeSpan);
          i = end + 1;
          continue;
        }
      }
      // Strong: **...** or __...__.
      if ((c == 0x2a || c == 0x5f) &&
          i + 1 < n &&
          text.codeUnitAt(i + 1) == c) {
        final marker = String.fromCharCodes([c, c]);
        final end = text.indexOf(marker, i + 2);
        if (end > i) {
          b.add(text.substring(i, end + 2), TokenType.strong);
          i = end + 2;
          continue;
        }
      }
      // Emphasis: *...* or _..._.
      if (c == 0x2a || c == 0x5f) {
        final end = text.indexOf(String.fromCharCode(c), i + 1);
        if (end > i) {
          b.add(text.substring(i, end + 1), TokenType.emphasis);
          i = end + 1;
          continue;
        }
      }
      // Link: [text](url).
      if (c == 0x5b) {
        final close = text.indexOf(']', i + 1);
        if (close > i && close + 1 < n && text.codeUnitAt(close + 1) == 0x28) {
          final paren = text.indexOf(')', close + 2);
          if (paren > close) {
            b.add(text.substring(i, paren + 1), TokenType.link);
            i = paren + 1;
            continue;
          }
        }
      }
      b.addChar(c, TokenType.plain);
      i++;
    }
  }
}
