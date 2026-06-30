import 'dart:async';
import 'dart:io';

import 'ansi_terminal_driver.dart';

export 'terminal_driver.dart';

/// Owns the real terminal for the duration of a full-screen TUI: it switches to
/// the alternate screen buffer and raw mode on [enter], restores everything on
/// [leave], exposes the terminal [size] and resize notifications, and writes
/// rendered frames via [present].
///
/// The class is deliberately the only part of the IDE that touches `dart:io`
/// terminal state, so the rest of the engine stays pure and testable. The ANSI
/// frame emission (alt-screen/SGR/cursor + [ScreenBuffer] diffing) is shared
/// with web drivers via [AnsiTerminalDriver]; this class adds the stdout sink,
/// terminal size, raw mode and flow-control management.
class Terminal extends AnsiTerminalDriver {
  Terminal({Stdin? stdin, Stdout? stdout, Stream<List<int>>? inputOverride})
    : _stdin = stdin ?? defaultStdin,
      _stdout = stdout ?? defaultStdout,
      _inputOverride = inputOverride;

  final Stdin _stdin;
  final Stdout _stdout;

  /// When set, raw input is read from this stream instead of `stdin` directly.
  /// The CLI host owns the single stdin subscription and forwards bytes here, so
  /// the IDE must not `listen` to stdin itself.
  final Stream<List<int>>? _inputOverride;

  bool _entered = false;
  bool _prevEcho = true;
  bool _prevLine = true;

  /// The terminal's saved `stty` settings (from `stty -g`) captured on [enter]
  /// so flow control can be restored verbatim on [leave]. Null when capture
  /// failed or the platform has no POSIX `stty`.
  String? _savedStty;

  /// The current terminal size in cells, falling back to 80x24 when the size is
  /// unavailable (e.g. a redirected stdout).
  @override
  ({int cols, int rows}) get size {
    var cols = 80, rows = 24;
    try {
      if (_stdout.hasTerminal) {
        cols = _stdout.terminalColumns;
        rows = _stdout.terminalLines;
      }
    } on Object {
      // Some platforms throw when the size is unknown; keep the fallback.
    }
    return (cols: cols < 1 ? 80 : cols, rows: rows < 1 ? 24 : rows);
  }

  /// Writes already-encoded ANSI/text to stdout (the [AnsiTerminalDriver] sink).
  @override
  void writeAnsi(String ansi) => _stdout.write(ansi);

  /// Enters full-screen mode (idempotent): saves the input mode, enables raw
  /// input and disables flow control, before [AnsiTerminalDriver.enter] switches
  /// to the alternate screen. A second call is a no-op.
  @override
  void enter() {
    if (_entered) return;
    _entered = true;
    super.enter();
  }

  /// Leaves full-screen mode (idempotent), restoring the main screen via
  /// [AnsiTerminalDriver.leave] then the prior input/flow-control mode.
  @override
  void leave() {
    if (!_entered) return;
    _entered = false;
    super.leave();
  }

  @override
  void onEnter() {
    try {
      _prevEcho = _stdin.echoMode;
      _prevLine = _stdin.lineMode;
    } on Object {
      _prevEcho = true;
      _prevLine = true;
    }
    _setRaw(true);
    _disableFlowControl();
  }

  @override
  void onLeave() {
    _restoreFlowControl();
    _setRaw(false);
  }

  /// The raw input byte stream (valid while [enter] is in effect): the host's
  /// forwarded stream when one was provided, else `stdin` directly.
  @override
  Stream<List<int>> get input => _inputOverride ?? _stdin;

  /// Terminal resize notifications, or an empty stream where unsupported
  /// (Windows, or no controlling terminal).
  @override
  Stream<void> get resizeEvents {
    try {
      if (!Platform.isWindows) {
        return ProcessSignal.sigwinch.watch().map((_) {});
      }
    } on Object {
      // SIGWINCH not available; fall through.
    }
    return const Stream<void>.empty();
  }

  void _setRaw(bool raw) {
    try {
      _stdin.echoMode = raw ? false : _prevEcho;
      _stdin.lineMode = raw ? false : _prevLine;
    } on Object {
      // Non-TTY stdin or a platform that rejects the change: leave as-is.
    }
  }

  /// Disables terminal software flow control (`IXON`/`IXOFF`) for the duration
  /// of the full-screen session.
  ///
  /// Dart's `lineMode = false` clears `ICANON` but leaves `IXON` on, so on a
  /// typical POSIX terminal (e.g. macOS Terminal) `Ctrl-S` (XOFF) and `Ctrl-Q`
  /// (XON) are swallowed by the tty driver as flow control and never reach the
  /// app — which is why `Ctrl-Q` (quit) and `Ctrl-S` (save) appear dead. There
  /// is no Dart API for `IXON`, so shell out to `stty`, operating on the
  /// controlling terminal (`/dev/tty`) since this process's stdin may be a pipe.
  /// The previous settings are captured via `stty -g` for verbatim restore on
  /// [leave]. No-op on Windows and best-effort everywhere (failures are
  /// ignored, leaving the prior `Ctrl-Q`-is-flow-control behaviour).
  void _disableFlowControl() {
    if (Platform.isWindows) return;
    try {
      final saved = Process.runSync('sh', ['-c', 'stty -g </dev/tty']);
      if (saved.exitCode == 0) {
        _savedStty = (saved.stdout as String).trim();
      }
      Process.runSync('sh', ['-c', 'stty -ixon -ixoff </dev/tty']);
    } on Object {
      // No `stty`, no controlling terminal, or a sandbox that blocks exec:
      // leave flow control as-is.
    }
  }

  /// Restores the flow-control settings captured by [_disableFlowControl].
  void _restoreFlowControl() {
    final saved = _savedStty;
    _savedStty = null;
    if (saved == null || saved.isEmpty) return;
    try {
      Process.runSync('sh', ['-c', 'stty $saved </dev/tty']);
    } on Object {
      // Best-effort restore; ignore failures.
    }
  }
}

/// Indirection so [Terminal]'s defaults can be overridden in tests without
/// importing `dart:io` symbols at every call site.
Stdin get defaultStdin => stdin;
Stdout get defaultStdout => stdout;
