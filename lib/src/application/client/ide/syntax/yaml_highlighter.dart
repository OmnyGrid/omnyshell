import 'highlighter.dart';
import 'scan_utils.dart';

/// A line-oriented YAML highlighter: comments (`#`), document markers
/// (`---`/`...`), `key:` mapping keys, `-` sequence markers, quoted strings,
/// numbers and `true`/`false`/`null`-style constants. Block scalars are not
/// tracked across lines (their content renders as plain text), which keeps the
/// highlighter stateless and predictable.
class YamlHighlighter extends Highlighter {
  const YamlHighlighter();

  @override
  String get language => 'YAML';

  static const _constants = {
    'true',
    'false',
    'null',
    'yes',
    'no',
    'on',
    'off',
    'True',
    'False',
    'Null',
    'TRUE',
    'FALSE',
    'NULL',
    '~',
  };

  @override
  LineHighlight highlight(String line, HighlightState state, TokenTheme theme) {
    final b = RunBuilder(theme);
    final s = line;
    final n = s.length;
    var i = 0;

    // Leading whitespace.
    while (i < n && isSpace(s.codeUnitAt(i))) {
      i++;
    }
    b.add(s.substring(0, i), TokenType.plain);

    // Full-line comment.
    if (i < n && s.codeUnitAt(i) == 0x23) {
      b.add(s.substring(i), TokenType.comment);
      return LineHighlight(b.build(), HighlightState.none);
    }

    // Document markers.
    final rest = s.substring(i);
    if (rest == '---' || rest == '...') {
      b.add(rest, TokenType.punctuation);
      return LineHighlight(b.build(), HighlightState.none);
    }

    // Leading sequence markers ("- " possibly repeated).
    while (i + 1 < n &&
        s.codeUnitAt(i) == 0x2d &&
        isSpace(s.codeUnitAt(i + 1))) {
      b.add('-', TokenType.listMarker);
      i++;
      final ws = _spanSpaces(s, i);
      b.add(s.substring(i, ws), TokenType.plain);
      i = ws;
    }
    // A bare "-" line.
    if (i == n - 1 && s.codeUnitAt(i) == 0x2d) {
      b.add('-', TokenType.listMarker);
      return LineHighlight(b.build(), HighlightState.none);
    }

    // Try to split "key:" — find a colon that ends the key (followed by space
    // or end of line) before any value.
    final keyEnd = _findKeyColon(s, i);
    if (keyEnd >= 0) {
      b.add(s.substring(i, keyEnd), TokenType.property);
      b.add(':', TokenType.punctuation);
      i = keyEnd + 1;
    }

    // Remainder: a value (with a possible inline comment).
    _highlightValue(b, s, i);
    return LineHighlight(b.build(), HighlightState.none);
  }

  int _spanSpaces(String s, int from) {
    var i = from;
    while (i < s.length && isSpace(s.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  /// Returns the index of the colon that terminates a mapping key starting at
  /// [from], or -1 if the line is not `key:`-shaped. A key colon is one not
  /// inside quotes and immediately followed by a space or end of line.
  int _findKeyColon(String s, int from) {
    final n = s.length;
    var i = from;
    int? quote;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (quote != null) {
        if (c == quote) quote = null;
        i++;
        continue;
      }
      if (c == 0x27 || c == 0x22) {
        quote = c;
        i++;
        continue;
      }
      if (c == 0x23) return -1; // comment before any colon — not a key
      if (c == 0x3a && (i + 1 >= n || isSpace(s.codeUnitAt(i + 1)))) {
        return i;
      }
      i++;
    }
    return -1;
  }

  /// Highlights the value region [from..end), handling an inline ` #` comment,
  /// quoted strings, numbers, anchors/aliases and constants; everything else is
  /// plain.
  void _highlightValue(RunBuilder b, String s, int from) {
    final n = s.length;
    var i = from;
    while (i < n) {
      final c = s.codeUnitAt(i);
      // Inline comment: '#' preceded by whitespace.
      if (c == 0x23 && i > 0 && isSpace(s.codeUnitAt(i - 1))) {
        b.add(s.substring(i), TokenType.comment);
        return;
      }
      if (c == 0x27 || c == 0x22) {
        var j = i + 1;
        while (j < n && s.codeUnitAt(j) != c) {
          j++;
        }
        if (j < n) j++;
        b.add(s.substring(i, j), TokenType.string);
        i = j;
        continue;
      }
      if (c == 0x26 || c == 0x2a) {
        // &anchor / *alias
        var j = i + 1;
        while (j < n && isIdentPart(s.codeUnitAt(j))) {
          j++;
        }
        b.add(s.substring(i, j), TokenType.attribute);
        i = j;
        continue;
      }
      if (isSpace(c)) {
        b.addChar(c, TokenType.plain);
        i++;
        continue;
      }
      // A whitespace-delimited token: classify as number / constant / plain.
      var j = i;
      while (j < n && !isSpace(s.codeUnitAt(j))) {
        j++;
      }
      final token = s.substring(i, j);
      b.add(token, _classify(token));
      i = j;
    }
  }

  TokenType _classify(String token) {
    if (_constants.contains(token)) return TokenType.constant;
    if (_looksNumeric(token)) return TokenType.number;
    return TokenType.plain;
  }

  bool _looksNumeric(String token) {
    if (token.isEmpty) return false;
    var seenDigit = false;
    for (var k = 0; k < token.length; k++) {
      final c = token.codeUnitAt(k);
      if (isDigit(c)) {
        seenDigit = true;
      } else if (c != 0x2e && c != 0x2d && c != 0x2b && (c | 0x20) != 0x65) {
        return false;
      }
    }
    return seenDigit;
  }
}
