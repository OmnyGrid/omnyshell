import 'highlighter.dart';

/// Accumulates `(text, TokenType)` pieces while a highlighter scans a line, then
/// materialises them into [StyledRun]s against a [TokenTheme]. Consecutive
/// pieces of the same token type are merged so the renderer emits fewer runs.
class RunBuilder {
  final List<StyledRun> _runs = [];
  final StringBuffer _pending = StringBuffer();
  TokenType? _pendingType;
  final TokenTheme theme;

  RunBuilder(this.theme);

  /// Appends [text] as token [type] (no-op for empty text).
  void add(String text, TokenType type) {
    if (text.isEmpty) return;
    if (_pendingType == type) {
      _pending.write(text);
      return;
    }
    _flushPending();
    _pendingType = type;
    _pending.write(text);
  }

  /// Appends a single character (by code unit) as token [type].
  void addChar(int codeUnit, TokenType type) =>
      add(String.fromCharCode(codeUnit), type);

  void _flushPending() {
    if (_pending.isEmpty) return;
    _runs.add(StyledRun(_pending.toString(), theme.styleFor(_pendingType!)));
    _pending.clear();
  }

  /// The accumulated runs (flushing any pending piece).
  List<StyledRun> build() {
    _flushPending();
    return _runs;
  }
}

/// Whether [c] (a code unit) may start an identifier (`A–Z a–z _ $`).
bool isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c == 0x24;

/// Whether [c] may continue an identifier ([isIdentStart] or a digit).
bool isIdentPart(int c) => isIdentStart(c) || isDigit(c);

/// Whether [c] is an ASCII digit.
bool isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Whether [c] is an ASCII upper-case letter (used to guess type names).
bool isUpper(int c) => c >= 0x41 && c <= 0x5a;

/// Whether [c] is ASCII whitespace.
bool isSpace(int c) => c == 0x20 || c == 0x09;
