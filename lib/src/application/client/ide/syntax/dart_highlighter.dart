import 'highlighter.dart';
import 'scan_utils.dart';

/// A single-pass Dart syntax highlighter.
///
/// Handles line (`//`, `///`) and block (`/* */`) comments, single/double and
/// raw strings, triple-quoted multi-line strings, numbers, annotations (`@foo`),
/// keywords, capitalised type names and call-site function names. Multi-line
/// constructs are carried across lines via [HighlightState.mode]:
///
/// * `1` — inside a `/* … */` block comment;
/// * `2` — inside a `''' … '''` string;
/// * `3` — inside a `""" … """` string.
class DartHighlighter extends Highlighter {
  const DartHighlighter();

  @override
  String get language => 'Dart';

  static const _inBlockComment = 1;
  static const _inTripleSingle = 2;
  static const _inTripleDouble = 3;

  static const _keywords = {
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'base',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'Function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'sealed',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'when',
    'while',
    'with',
    'yield',
  };

  static const _builtinTypes = {
    'int',
    'double',
    'num',
    'bool',
    'String',
    'List',
    'Map',
    'Set',
    'Object',
    'Future',
    'Stream',
    'Iterable',
    'void',
    'dynamic',
    'Null',
    'Never',
  };

  @override
  LineHighlight highlight(String line, HighlightState state, TokenTheme theme) {
    final b = RunBuilder(theme);
    final s = line;
    final n = s.length;
    var i = 0;
    var mode = state.mode;

    // Resume a carried multi-line construct first.
    if (mode == _inBlockComment) {
      final end = s.indexOf('*/');
      if (end < 0) {
        b.add(s, TokenType.comment);
        return LineHighlight(b.build(), const HighlightState(_inBlockComment));
      }
      b.add(s.substring(0, end + 2), TokenType.comment);
      i = end + 2;
      mode = 0;
    } else if (mode == _inTripleSingle || mode == _inTripleDouble) {
      final close = mode == _inTripleSingle ? "'''" : '"""';
      final end = s.indexOf(close);
      if (end < 0) {
        b.add(s, TokenType.string);
        return LineHighlight(b.build(), HighlightState(mode));
      }
      b.add(s.substring(0, end + 3), TokenType.string);
      i = end + 3;
      mode = 0;
    }

    while (i < n) {
      final c = s.codeUnitAt(i);

      // Comments.
      if (c == 0x2f && i + 1 < n) {
        final next = s.codeUnitAt(i + 1);
        if (next == 0x2f) {
          b.add(s.substring(i), TokenType.comment);
          return LineHighlight(b.build(), HighlightState.none);
        }
        if (next == 0x2a) {
          final end = s.indexOf('*/', i + 2);
          if (end < 0) {
            b.add(s.substring(i), TokenType.comment);
            return LineHighlight(
              b.build(),
              const HighlightState(_inBlockComment),
            );
          }
          b.add(s.substring(i, end + 2), TokenType.comment);
          i = end + 2;
          continue;
        }
      }

      // Annotations: @identifier.
      if (c == 0x40) {
        var j = i + 1;
        while (j < n && isIdentPart(s.codeUnitAt(j))) {
          j++;
        }
        b.add(s.substring(i, j), TokenType.attribute);
        i = j;
        continue;
      }

      // Raw strings: r'…' / r"…".
      if ((c == 0x72) &&
          i + 1 < n &&
          (s.codeUnitAt(i + 1) == 0x27 || s.codeUnitAt(i + 1) == 0x22)) {
        final consumed = _scanString(s, i + 1, raw: true);
        b.add(s.substring(i, consumed.end), TokenType.string);
        i = consumed.end;
        if (consumed.carry != 0) {
          return LineHighlight(b.build(), HighlightState(consumed.carry));
        }
        continue;
      }

      // Strings (including triple-quoted).
      if (c == 0x27 || c == 0x22) {
        final consumed = _scanString(s, i, raw: false);
        b.add(s.substring(i, consumed.end), TokenType.string);
        i = consumed.end;
        if (consumed.carry != 0) {
          return LineHighlight(b.build(), HighlightState(consumed.carry));
        }
        continue;
      }

      // Numbers.
      if (isDigit(c) ||
          (c == 0x2e && i + 1 < n && isDigit(s.codeUnitAt(i + 1)))) {
        var j = i;
        // Hex.
        if (c == 0x30 && i + 1 < n && (s.codeUnitAt(i + 1) | 0x20) == 0x78) {
          j = i + 2;
          while (j < n && _isHex(s.codeUnitAt(j))) {
            j++;
          }
        } else {
          while (j < n &&
              (isDigit(s.codeUnitAt(j)) ||
                  s.codeUnitAt(j) == 0x2e ||
                  (s.codeUnitAt(j) | 0x20) == 0x65 || // e/E
                  s.codeUnitAt(j) == 0x5f)) {
            j++;
          }
        }
        b.add(s.substring(i, j), TokenType.number);
        i = j;
        continue;
      }

      // Identifiers / keywords / types / calls.
      if (isIdentStart(c)) {
        var j = i + 1;
        while (j < n && isIdentPart(s.codeUnitAt(j))) {
          j++;
        }
        final word = s.substring(i, j);
        // Look past spaces for a '(' to detect a call.
        var k = j;
        while (k < n && isSpace(s.codeUnitAt(k))) {
          k++;
        }
        final isCall = k < n && s.codeUnitAt(k) == 0x28;
        if (_keywords.contains(word)) {
          b.add(word, TokenType.keyword);
        } else if (_builtinTypes.contains(word) || isUpper(c)) {
          b.add(word, TokenType.type);
        } else if (isCall) {
          b.add(word, TokenType.function);
        } else {
          b.add(word, TokenType.plain);
        }
        i = j;
        continue;
      }

      // Operators / punctuation.
      if (_isOperator(c)) {
        b.addChar(c, TokenType.operatorTok);
      } else if (_isPunct(c)) {
        b.addChar(c, TokenType.punctuation);
      } else {
        b.addChar(c, TokenType.plain);
      }
      i++;
    }

    return LineHighlight(b.build(), HighlightState(mode));
  }

  /// Scans a string literal starting at [start] (the opening quote). Returns the
  /// index just past the string and the carry mode (`0` if the string closed on
  /// this line, else the triple-quote mode to resume).
  ({int end, int carry}) _scanString(String s, int start, {required bool raw}) {
    final n = s.length;
    final quote = s.codeUnitAt(start);
    final triple =
        start + 2 < n &&
        s.codeUnitAt(start + 1) == quote &&
        s.codeUnitAt(start + 2) == quote;
    if (triple) {
      final close = quote == 0x27 ? "'''" : '"""';
      final end = s.indexOf(close, start + 3);
      if (end < 0) {
        return (
          end: n,
          carry: quote == 0x27 ? _inTripleSingle : _inTripleDouble,
        );
      }
      return (end: end + 3, carry: 0);
    }
    var i = start + 1;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (!raw && c == 0x5c) {
        i += 2; // skip escape
        continue;
      }
      if (c == quote) return (end: i + 1, carry: 0);
      i++;
    }
    return (end: n, carry: 0); // unterminated single-line string
  }

  static bool _isHex(int c) =>
      isDigit(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66);

  static bool _isOperator(int c) =>
      c == 0x2b || // +
      c == 0x2d || // -
      c == 0x2a || // *
      c == 0x2f || // /
      c == 0x25 || // %
      c == 0x3d || // =
      c == 0x3c || // <
      c == 0x3e || // >
      c == 0x21 || // !
      c == 0x26 || // &
      c == 0x7c || // |
      c == 0x5e || // ^
      c == 0x7e || // ~
      c == 0x3f; // ?

  static bool _isPunct(int c) =>
      c == 0x28 ||
      c == 0x29 ||
      c == 0x7b ||
      c == 0x7d ||
      c == 0x5b ||
      c == 0x5d ||
      c == 0x3b ||
      c == 0x2c ||
      c == 0x2e ||
      c == 0x3a;
}
