import 'key.dart';
import 'key_decoder.dart';
import 'screen_buffer.dart';

/// The terminal capabilities the IDE engine depends on, kept `dart:io`-free so
/// the engine compiles to JavaScript. The native [Terminal] (in `terminal.dart`)
/// implements it for a real TTY; tests provide a fake; a web app provides its
/// own driver feeding the rendered frames to a browser terminal widget.
abstract interface class TerminalDriver {
  /// The current size in cells.
  ({int cols, int rows}) get size;

  /// Enters full-screen mode (alternate screen + raw input).
  ///
  /// With [mouseWheel], also asks the terminal to report the mouse wheel, which
  /// the [KeyDecoder] turns into [KeyType.wheelUp]/[KeyType.wheelDown]. It is
  /// opt-in because while it is on most terminals stop selecting text on a
  /// plain drag and pasting on a middle-click (with Shift held — Option/Fn on
  /// macOS — both still work).
  void enter({bool mouseWheel = false});

  /// Leaves full-screen mode, restoring the prior screen and input mode.
  void leave();

  /// Renders [frame], diffed against the previous one, optionally placing the
  /// hardware cursor.
  void present(ScreenBuffer frame, {int? cursorX, int? cursorY});

  /// Forces the next [present] to repaint in full.
  void invalidate();

  /// The raw input byte stream.
  Stream<List<int>> get input;

  /// Terminal resize notifications.
  Stream<void> get resizeEvents;
}
