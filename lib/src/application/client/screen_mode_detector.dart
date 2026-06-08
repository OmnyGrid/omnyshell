/// Detects when the remote terminal switches into or out of the **alternate
/// screen buffer**, by watching the output byte stream for the DEC private-mode
/// sequences full-screen programs emit:
///
/// - enter: `ESC [ ? 1049 h` (also the older `ESC [ ? 1047 h`)
/// - leave: `ESC [ ? 1049 l` (also the older `ESC [ ? 1047 l`)
///
/// `nano`, `vim`, `less`, `top` and `htop` all toggle the alternate screen this
/// way. The `connect` client uses the transition to switch its [LineEditor]
/// between local line editing and raw passthrough: while a full-screen app owns
/// the screen, keystrokes must reach the app unmodified rather than being parsed
/// as a local command line.
///
/// The detector is a passive observer — it never alters the bytes (they are
/// still forwarded to the local terminal so it mirrors the alternate-screen
/// switch). Sequences split across [feed] chunks are handled by carrying over a
/// short suffix between calls.
class ScreenModeDetector {
  /// Whether the remote terminal is currently in the alternate screen buffer.
  bool inAltScreen = false;

  // The recognised toggles, longest first is irrelevant since all share length.
  static const List<int> _enter1049 = [
    0x1b,
    0x5b,
    0x3f,
    0x31,
    0x30,
    0x34,
    0x39,
    0x68,
  ]; // ESC[?1049h
  static const List<int> _leave1049 = [
    0x1b,
    0x5b,
    0x3f,
    0x31,
    0x30,
    0x34,
    0x39,
    0x6c,
  ]; // ESC[?1049l
  static const List<int> _enter1047 = [
    0x1b,
    0x5b,
    0x3f,
    0x31,
    0x30,
    0x34,
    0x37,
    0x68,
  ]; // ESC[?1047h
  static const List<int> _leave1047 = [
    0x1b,
    0x5b,
    0x3f,
    0x31,
    0x30,
    0x34,
    0x37,
    0x6c,
  ]; // ESC[?1047l

  /// Length of the longest recognised sequence; we retain up to one less than
  /// this many trailing bytes between chunks so a split sequence still matches.
  static const int _maxSeqLen = 8;

  final List<int> _carry = [];

  /// Feeds a chunk of remote output. Returns `true` when [inAltScreen] changed
  /// as a result. Never modifies or consumes the forwarded bytes.
  bool feed(List<int> chunk) {
    final window = _carry.isEmpty ? chunk : [..._carry, ...chunk];
    final before = inAltScreen;

    for (var i = 0; i < window.length; i++) {
      if (_matchAt(window, i, _enter1049) || _matchAt(window, i, _enter1047)) {
        inAltScreen = true;
      } else if (_matchAt(window, i, _leave1049) ||
          _matchAt(window, i, _leave1047)) {
        inAltScreen = false;
      }
    }

    // Retain a trailing suffix that could be the prefix of a split sequence.
    _carry
      ..clear()
      ..addAll(
        window.length <= _maxSeqLen - 1
            ? window
            : window.sublist(window.length - (_maxSeqLen - 1)),
      );

    return inAltScreen != before;
  }

  /// Clears carried state and resets to the non-alternate screen.
  void reset() {
    _carry.clear();
    inAltScreen = false;
  }

  static bool _matchAt(List<int> data, int at, List<int> seq) {
    if (at + seq.length > data.length) return false;
    for (var j = 0; j < seq.length; j++) {
      if (data[at + j] != seq[j]) return false;
    }
    return true;
  }
}
