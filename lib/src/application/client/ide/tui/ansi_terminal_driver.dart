import 'screen_buffer.dart';
import 'terminal_driver.dart';

/// A [TerminalDriver] base that turns [ScreenBuffer] frames into ANSI byte
/// output, leaving the byte sink, size, and input/resize streams to subclasses.
///
/// The alternate-screen / SGR / cursor sequences and the frame diffing are
/// identical for every terminal, so they live here once and are shared by the
/// native TTY driver (`Terminal`, which writes to stdout and manages raw mode)
/// and browser drivers (which write to a terminal widget). Subclasses implement
/// [writeAnsi] (the sink) plus [size]/[input]/[resizeEvents] (from
/// [TerminalDriver]), and may override [onEnter]/[onLeave] for sink-specific
/// setup such as raw mode or flow control.
abstract class AnsiTerminalDriver implements TerminalDriver {
  ScreenBuffer? _front; // the last frame presented, for diffing.

  /// Writes [ansi] (already-encoded escape/text) to the underlying terminal.
  void writeAnsi(String ansi);

  /// Hook run during [enter], before the alternate-screen sequence is written
  /// (e.g. enable raw mode / disable flow control). Default: no-op.
  void onEnter() {}

  /// Hook run during [leave], after the screen-restore sequence is written
  /// (e.g. restore the previous input mode). Default: no-op.
  void onLeave() {}

  /// Whether the last [enter] turned mouse reporting on, so [leave] knows to
  /// turn it off again (a terminal left in mouse mode would keep writing
  /// reports into the user's shell).
  bool _mouseWheelEnabled = false;

  /// Mouse reporting on: mode 1000 reports button presses — the wheel arrives
  /// as buttons 4/5, and no narrower mode reports the wheel alone — and mode
  /// 1006 asks for the SGR encoding (`ESC [ < b ; x ; y M`), which has no
  /// coordinate limit and is all ASCII. Terminals without 1006 fall back to the
  /// legacy `ESC [ M b x y` form, which [KeyDecoder] also understands.
  static const _mouseOn = '\x1b[?1000h\x1b[?1006h';

  /// Mouse reporting off, the reverse of [_mouseOn].
  static const _mouseOff = '\x1b[?1006l\x1b[?1000l';

  @override
  void enter({bool mouseWheel = false}) {
    onEnter();
    // Alternate screen on, clear, cursor home, hide cursor.
    // A re-enter without a leave() between (only [Terminal] guards against
    // that) must not strand mouse mode on with the flag cleared, or leave()
    // would never turn it off; so switch it off here when it is no longer
    // wanted.
    final mouse = mouseWheel ? _mouseOn : (_mouseWheelEnabled ? _mouseOff : '');
    writeAnsi('\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l$mouse');
    _mouseWheelEnabled = mouseWheel;
    _front = null;
  }

  @override
  void leave() {
    // Reset attributes, show cursor, leave the alternate screen.
    writeAnsi(
      '${_mouseWheelEnabled ? _mouseOff : ''}\x1b[0m\x1b[?25h\x1b[?1049l',
    );
    _mouseWheelEnabled = false;
    onLeave();
    _front = null;
  }

  @override
  void present(ScreenBuffer frame, {int? cursorX, int? cursorY}) {
    final out =
        StringBuffer('\x1b[?25l') // hide while painting
          ..write(frame.renderDiff(_front));
    if (cursorX != null && cursorY != null) {
      out.write('\x1b[${cursorY + 1};${cursorX + 1}H\x1b[?25h');
    }
    writeAnsi(out.toString());
    _front = frame;
  }

  @override
  void invalidate() => _front = null;
}
