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

  @override
  void enter() {
    onEnter();
    // Alternate screen on, clear, cursor home, hide cursor.
    writeAnsi('\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l');
    _front = null;
  }

  @override
  void leave() {
    // Reset attributes, show cursor, leave the alternate screen.
    writeAnsi('\x1b[0m\x1b[?25h\x1b[?1049l');
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
