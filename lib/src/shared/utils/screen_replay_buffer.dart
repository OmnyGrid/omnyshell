import 'dart:typed_data';

/// A bounded capture of recent terminal output that also tracks the
/// **alternate screen** state, so a detached session can be repainted on resume.
///
/// Unlike a plain ring buffer, this is fed *continuously* for the whole life of
/// a session (attached and detached) and understands the DEC private-mode
/// toggles full-screen programs emit:
///
/// - enter: `ESC [ ? 1049 h` (and the older `ESC [ ? 1047 h`)
/// - leave: `ESC [ ? 1049 l` (and the older `ESC [ ? 1047 l`)
///
/// On resume, [replaySnapshot] returns the bytes needed to reconstruct the
/// current screen: for a full-screen program, everything since the last
/// alt-screen *enter* (so the client re-enters the alt buffer and receives the
/// program's whole draw history → its current frame); for a normal shell, the
/// retained scrollback tail. The same byte patterns are recognised by the
/// client's `ScreenModeDetector`; this is the node-side, retaining counterpart.
class ScreenReplayBuffer {
  /// The maximum number of bytes retained. Older bytes are dropped.
  final int capacity;

  /// Creates a replay buffer retaining at most [capacity] bytes (default 1 MiB,
  /// generous enough to hold a full-screen program's redraws since it entered
  /// the alternate screen).
  ScreenReplayBuffer({this.capacity = 1024 * 1024})
    : assert(capacity > 0, 'capacity must be positive');

  final BytesBuilder _buf = BytesBuilder(copy: false);

  /// Absolute index (over all bytes ever added) of the first retained byte.
  int _bufStartAbs = 0;

  /// Total number of bytes ever added.
  int _writtenAbs = 0;

  /// Absolute index of the start of the most recent alt-screen *enter*, or
  /// `null` if none is known (never seen, or trimmed away).
  int? _lastAltEnterAbs;

  bool _inAltScreen = false;

  // Rolling window of the last up-to-8 bytes, for matching toggles that may be
  // split across [add] calls.
  final List<int> _window = [];

  /// Whether the captured stream is currently in the alternate screen buffer.
  bool get inAltScreen => _inAltScreen;

  /// The number of bytes currently retained.
  int get length => _buf.length;

  static const List<int> _enter1049 = [
    0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68, // ESC[?1049h
  ];
  static const List<int> _leave1049 = [
    0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c, // ESC[?1049l
  ];
  static const List<int> _enter1047 = [
    0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x37, 0x68, // ESC[?1047h
  ];
  static const List<int> _leave1047 = [
    0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x37, 0x6c, // ESC[?1047l
  ];

  /// Appends [data], updating the alt-screen state and dropping the oldest
  /// bytes once [capacity] is exceeded.
  void add(List<int> data) {
    if (data.isEmpty) return;
    for (final b in data) {
      _window.add(b);
      if (_window.length > 8) _window.removeAt(0);
      if (_window.length == 8) {
        if (_eq(_window, _enter1049) || _eq(_window, _enter1047)) {
          _inAltScreen = true;
          _lastAltEnterAbs = _writtenAbs - 7; // start of the 8-byte sequence
        } else if (_eq(_window, _leave1049) || _eq(_window, _leave1047)) {
          _inAltScreen = false;
        }
      }
      _writtenAbs++;
    }
    _buf.add(data is Uint8List ? data : Uint8List.fromList(data));
    _trim();
  }

  void _trim() {
    if (_buf.length <= capacity) return;
    final bytes = _buf.takeBytes();
    final drop = bytes.length - capacity;
    _bufStartAbs += drop;
    _buf.add(Uint8List.sublistView(bytes, drop));
    // If the last alt-enter scrolled out of the retained window, it is lost; a
    // resume then replays the whole tail (best effort) instead.
    if (_lastAltEnterAbs != null && _lastAltEnterAbs! < _bufStartAbs) {
      _lastAltEnterAbs = null;
    }
  }

  /// Returns the bytes that reconstruct the current screen on resume, without
  /// consuming the buffer (the session continues after a resume).
  Uint8List replaySnapshot() {
    final bytes = _buf.toBytes();
    if (_inAltScreen &&
        _lastAltEnterAbs != null &&
        _lastAltEnterAbs! >= _bufStartAbs) {
      return Uint8List.sublistView(bytes, _lastAltEnterAbs! - _bufStartAbs);
    }
    return bytes;
  }

  static bool _eq(List<int> a, List<int> b) {
    for (var i = 0; i < 8; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
