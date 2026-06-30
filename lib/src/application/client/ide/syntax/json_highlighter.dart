import 'highlighter.dart';
import 'scan_utils.dart';

/// A JSON highlighter: object keys (a string immediately before `:`) render as
/// properties, other strings as strings, plus numbers, `true`/`false`/`null`
/// literals, and punctuation. JSON strings do not span lines, so no carry state
/// is needed.
class JsonHighlighter extends Highlighter {
  const JsonHighlighter();

  @override
  String get language => 'JSON';

  @override
  LineHighlight highlight(String line, HighlightState state, TokenTheme theme) {
    final b = RunBuilder(theme);
    final s = line;
    final n = s.length;
    var i = 0;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (c == 0x22) {
        // String: scan to the closing unescaped quote.
        var j = i + 1;
        while (j < n) {
          final d = s.codeUnitAt(j);
          if (d == 0x5c) {
            j += 2;
            continue;
          }
          if (d == 0x22) {
            j++;
            break;
          }
          j++;
        }
        // Property if the next non-space character is a colon.
        var k = j;
        while (k < n && isSpace(s.codeUnitAt(k))) {
          k++;
        }
        final isKey = k < n && s.codeUnitAt(k) == 0x3a;
        b.add(s.substring(i, j), isKey ? TokenType.property : TokenType.string);
        i = j;
        continue;
      }
      if (isDigit(c) ||
          (c == 0x2d && i + 1 < n && isDigit(s.codeUnitAt(i + 1)))) {
        var j = i + 1;
        while (j < n &&
            (isDigit(s.codeUnitAt(j)) ||
                s.codeUnitAt(j) == 0x2e ||
                (s.codeUnitAt(j) | 0x20) == 0x65 ||
                s.codeUnitAt(j) == 0x2b ||
                s.codeUnitAt(j) == 0x2d)) {
          j++;
        }
        b.add(s.substring(i, j), TokenType.number);
        i = j;
        continue;
      }
      if (isIdentStart(c)) {
        var j = i + 1;
        while (j < n && isIdentPart(s.codeUnitAt(j))) {
          j++;
        }
        final word = s.substring(i, j);
        final isLiteral = word == 'true' || word == 'false' || word == 'null';
        b.add(word, isLiteral ? TokenType.constant : TokenType.plain);
        i = j;
        continue;
      }
      if (c == 0x7b ||
          c == 0x7d ||
          c == 0x5b ||
          c == 0x5d ||
          c == 0x3a ||
          c == 0x2c) {
        b.addChar(c, TokenType.punctuation);
      } else {
        b.addChar(c, TokenType.plain);
      }
      i++;
    }
    return LineHighlight(b.build(), HighlightState.none);
  }
}
