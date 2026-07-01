import 'dart:async';
import 'dart:convert';

import 'command_history.dart';

/// A raw-mode line editor with command-history navigation.
///
/// Reads bytes from [input], echoes editing to [output], and delivers each
/// committed line to [onLine]. When [interactive] is true the terminal is put
/// into raw mode (via [setRawMode]) so arrow keys and other control sequences
/// are visible; the editor then implements its own line editing:
///
/// - Enter commits the line.
/// - Backspace / Delete edit around the cursor.
/// - Left / Right / Home / End (and Ctrl-A / Ctrl-E) move the cursor.
/// - Up / Down walk backward / forward through [history]; when text has been
///   typed, navigation is restricted to entries starting with that prefix.
/// - Ctrl-C discards the current line; Ctrl-D on an empty line signals EOF.
///
/// When [interactive] is false (piped input, no TTY) it degrades to plain
/// line-buffered reading with no history navigation, preserving non-interactive
/// use such as `echo ':info' | omnyshell connect ...`.
///
/// When [width] (the terminal column count) is known, the editor repaints
/// across every row a wrapped line occupies. When it is `0` (unknown) the
/// editor falls back to a single-row repaint, which staircases a fresh prompt
/// per keystroke once the prompt+input is wide enough to wrap — so hosts on a
/// terminal that can report its width should pass it and keep it current via
/// [setWidth]. (Display width is counted one column per rune, so double-width
/// CJK / emoji in the line may still misalign.)
class LineEditor {
  final Stream<List<int>> _input;
  final void Function(String) _output;
  final FutureOr<void> Function(String line) _onLine;
  final bool interactive;
  final CommandHistoryStore _history;
  final void Function(bool raw)? _setRawMode;
  final void Function()? _onInterrupt;
  final void Function()? _onEof;
  final void Function(List<int> bytes)? _onRaw;
  final Future<List<String>> Function(String word, bool isCommand)? _onComplete;

  StreamSubscription<Object?>? _sub;
  bool _closed = false;

  // While a full-screen takeover is active (see [suspendInput]), incoming bytes
  // are routed here instead of through the line-edit state machine, so the
  // editor's single stdin subscription is shared with the takeover rather than
  // cancelled and re-listened (stdin is single-subscription).
  void Function(List<int> data)? _rawSink;

  // When true, incoming bytes bypass the line-edit state machine entirely and
  // are forwarded verbatim to [_onRaw]. Used while a full-screen remote app
  // (e.g. nano/vim) owns the terminal, so its keystrokes reach it unmodified.
  bool _passthrough = false;

  // When true, the persistent *idle* prompt is not drawn (a local command like
  // the AI agent owns the screen). Explicit [prompt] questions still render.
  bool _promptHidden = false;

  // True while a committed line's handler ([_onLine]) is still running. Further
  // keystrokes are then ignored (so they neither echo over the command's output
  // nor leak as a new command) unless a [prompt] is awaiting an answer.
  bool _running = false;
  // Set while [prompt] is awaiting the next committed line (e.g. a `:download`
  // confirmation); that line completes this instead of running as a command.
  Completer<String>? _promptCompleter;

  // --- Editing state (interactive mode only) ---
  String _prompt = '';
  final List<String> _buffer = []; // one entry per user-visible character
  int _cursor = 0;

  // Terminal column count. 0 means "unknown" — the editor then repaints on a
  // single row (see class doc). Kept current by the host via [setWidth].
  int _width;
  // Visible width of [_prompt] (ANSI escapes stripped), cached by [setPrompt].
  int _promptWidth = 0;
  // Multi-row repaint bookkeeping: rows the last paint spanned and the cursor
  // position it left behind, so the next repaint can clear every wrapped row.
  int _lastRows = 0;
  int _lastPos = 0;

  // History navigation (index, stashed line, prefix) lives in this shared
  // cursor; an edit calls [_resetHistoryNav] so the next Up recomputes the
  // prefix from the current input.
  late final HistoryCursor _histCursor;

  // Escape-sequence parser state.
  _ParseState _state = _ParseState.normal;
  String _csiParams = '';
  // Pending bytes of an in-progress multi-byte UTF-8 character.
  final List<int> _utf8 = [];
  int _utf8Need = 0;

  LineEditor({
    required Stream<List<int>> input,
    required void Function(String) output,
    required FutureOr<void> Function(String line) onLine,
    required CommandHistoryStore history,
    this.interactive = true,
    int width = 0,
    void Function(bool raw)? setRawMode,
    void Function()? onInterrupt,
    void Function()? onEof,
    void Function(List<int> bytes)? onRaw,
    Future<List<String>> Function(String word, bool isCommand)? onComplete,
  }) : _input = input,
       _output = output,
       _onLine = onLine,
       _width = width,
       _history = history,
       _setRawMode = setRawMode,
       _onInterrupt = onInterrupt,
       _onEof = onEof,
       _onRaw = onRaw,
       _onComplete = onComplete {
    _histCursor = _history.cursor();
  }

  /// Records [line] in the history (subject to [CommandHistoryStore.add] rules)
  /// and
  /// resets the navigation cursor to the newest entry.
  Future<void> addHistory(String line) async {
    await _history.add(line);
    _histCursor.reset();
  }

  /// Updates the prompt shown before the input and repaints the current line.
  void setPrompt(String prompt) {
    _prompt = prompt;
    _promptWidth = _visibleWidth(prompt);
    if (interactive && !_passthrough) _refresh();
  }

  /// Updates the known terminal width (column count) and repaints, so wrapped
  /// lines reflow. Pass `0` when the width is unknown (single-row fallback).
  void setWidth(int cols) {
    if (cols == _width) return;
    _width = cols;
    if (interactive && !_passthrough) _refresh();
  }

  /// Reads a single line of input after showing [text], for a local command that
  /// needs an answer (e.g. a `:download` confirmation).
  ///
  /// The next committed line completes the returned future instead of being run
  /// as a command or added to history; Ctrl-C cancels it (completing with `''`).
  /// Works even though the triggering command is still running, because input is
  /// only gated when no prompt is pending.
  Future<String> prompt(String text) {
    final completer = Completer<String>();
    _promptCompleter = completer;
    _buffer.clear();
    _cursor = 0;
    setPrompt(text);
    return completer.future;
  }

  /// Whether a [prompt] is currently awaiting an answer (so a host can decide
  /// whether a Ctrl-C should unblock it).
  bool get hasPendingPrompt => _promptCompleter != null;

  /// Hides or restores the persistent *idle* prompt. While [hidden], the editor
  /// draws no prompt between commands (used so the AI agent owns the screen);
  /// an explicit [prompt] question still shows. The host repaints the prompt
  /// when restoring.
  void hideIdlePrompt(bool hidden) {
    if (_promptHidden == hidden) return;
    _promptHidden = hidden;
    if (interactive && !_passthrough && _promptCompleter == null) _refresh();
  }

  /// Enables or disables raw passthrough. While [on], bytes from the input are
  /// forwarded verbatim to `onRaw` (bypassing line editing); the local edit
  /// buffer and any partial escape/UTF-8 state are reset on each transition.
  void setPassthrough(bool on) {
    if (_passthrough == on) return;
    _passthrough = on;
    _state = _ParseState.normal;
    _csiParams = '';
    _utf8.clear();
    _utf8Need = 0;
    _buffer.clear();
    _cursor = 0;
    // Entering passthrough: erase whatever is on the current line — e.g. a
    // prompt a `printAbove` repaint left behind (the AI agent prints a `$ cmd`
    // header before its command runs) — so the program/command's output starts
    // on a clean line instead of after a dangling prompt. A committed command
    // always emits `\r\n` first, so in the normal flow this clears an empty line.
    if (on && interactive) _clearInputLine();
  }

  /// Handles a Ctrl-C that arrived out-of-band (raw mode keeps `ISIG` enabled,
  /// so the terminal raises `SIGINT` instead of delivering a `0x03` byte).
  ///
  /// In line mode it discards the current input, echoes `^C`, and notifies
  /// `onInterrupt`. In passthrough mode a full-screen app owns the screen, so it
  /// only notifies `onInterrupt` (which relays the signal to the remote app).
  void interrupt() {
    // During a full-screen takeover the editor must not touch the screen; the
    // takeover owns it (and uses its own quit key).
    if (_rawSink != null) return;
    if (_passthrough) {
      _onInterrupt?.call();
      return;
    }
    _interrupt();
  }

  /// Begins reading input. In non-interactive mode this simply splits [input]
  /// into lines; in interactive mode it enables raw terminal handling.
  void start() {
    if (!interactive) {
      _sub = _input
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) async {
            _sub?.pause();
            await _onLine(line);
            _sub?.resume();
          });
      return;
    }
    _setRawMode?.call(true);
    _sub = _input.listen(_onBytes);
  }

  /// Hands the input stream to [body] for the duration of a full-screen takeover
  /// (e.g. the `:ide` TUI), then resumes line editing.
  ///
  /// The editor's own input subscription is cancelled first so [body] can listen
  /// to the terminal directly (stdin is single-subscription); when [body]
  /// completes — however it returns or throws — the editor re-subscribes and
  /// repaints the current prompt line. In non-interactive mode it just runs
  /// [body]. The terminal's raw mode is left untouched (the editor already runs
  /// raw, and full-screen apps manage their own alternate screen on top).
  Future<R> suspendInput<R>(
    Future<R> Function(Stream<List<int>> input) body,
  ) async {
    // stdin is single-subscription, so the takeover cannot `listen` to it
    // itself. Instead the editor keeps its existing subscription and forwards
    // raw bytes into [controller], which [body] consumes as its input stream.
    final controller = StreamController<List<int>>();
    if (!interactive) {
      // No raw input to route; run the takeover against an empty stream.
      try {
        return await body(controller.stream);
      } finally {
        await controller.close();
      }
    }
    _rawSink = controller.add;
    try {
      return await body(controller.stream);
    } finally {
      _rawSink = null;
      await controller.close();
      // The takeover owned the screen; forget the old paint so the repaint
      // starts clean rather than clearing rows that are no longer ours.
      _resetRenderTracking();
      if (!_closed) _refresh();
    }
  }

  /// Stops reading and restores the terminal modes. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    if (interactive) _setRawMode?.call(false);
  }

  // ---------------------------------------------------------------------------
  // Byte handling
  // ---------------------------------------------------------------------------

  void _onBytes(List<int> data) {
    // Full-screen takeover (e.g. `:ide`): hand the bytes to the takeover and do
    // nothing else, so line editing stays dormant until it ends.
    final sink = _rawSink;
    if (sink != null) {
      sink(data);
      return;
    }
    // Raw passthrough: forward keystrokes straight to the remote app.
    if (_passthrough) {
      _onRaw?.call(data);
      return;
    }
    // A blocking command is running (e.g. a transfer): drop keystrokes so they
    // don't echo over its output or leak as a new command — unless a prompt is
    // waiting for an answer, which input must reach.
    if (_running && _promptCompleter == null) return;
    for (final b in data) {
      switch (_state) {
        case _ParseState.normal:
          if (b == 0x1b) {
            _state = _ParseState.esc;
          } else {
            _handleNormal(b);
          }
        case _ParseState.esc:
          // CSI (`[`) and SS3 (`O`) introduce the sequences we care about.
          if (b == 0x5b || b == 0x4f) {
            _state = _ParseState.csi;
            _csiParams = '';
          } else {
            _state = _ParseState.normal;
          }
        case _ParseState.csi:
          // Parameter/intermediate bytes accumulate; a final byte (0x40-0x7e)
          // ends the sequence.
          if (b >= 0x40 && b <= 0x7e) {
            _handleCsi(String.fromCharCode(b), _csiParams);
            _state = _ParseState.normal;
          } else {
            _csiParams += String.fromCharCode(b);
          }
      }
    }
  }

  void _handleNormal(int b) {
    // A continuation byte completes a pending multi-byte character.
    if (_utf8.isNotEmpty) {
      _utf8.add(b);
      if (_utf8.length >= _utf8Need) {
        _insert(utf8.decode(_utf8, allowMalformed: true));
        _utf8.clear();
        _utf8Need = 0;
      }
      return;
    }
    switch (b) {
      case 0x0d: // CR
      case 0x0a: // LF
        _commit();
      case 0x7f: // DEL
      case 0x08: // BS
        _backspace();
      case 0x03: // Ctrl-C
        _interrupt();
      case 0x04: // Ctrl-D
        if (_buffer.isEmpty) _onEof?.call();
      case 0x01: // Ctrl-A
        _moveHome();
      case 0x05: // Ctrl-E
        _moveEnd();
      case 0x09: // Tab
        _complete();
      default:
        if (b < 0x20) return; // other control chars: ignore
        if (b < 0x80) {
          _insert(String.fromCharCode(b));
        } else {
          // Lead byte of a multi-byte UTF-8 character.
          _utf8
            ..clear()
            ..add(b);
          _utf8Need = (b & 0xE0) == 0xC0
              ? 2
              : (b & 0xF0) == 0xE0
              ? 3
              : 4;
        }
    }
  }

  void _handleCsi(String fin, String params) {
    switch (fin) {
      case 'A': // Up
        _historyPrev();
      case 'B': // Down
        _historyNext();
      case 'C': // Right
        _moveRight();
      case 'D': // Left
        _moveLeft();
      case 'H': // Home
        _moveHome();
      case 'F': // End
        _moveEnd();
      case '~':
        // `1~`/`7~` Home, `4~`/`8~` End, `3~` Delete.
        if (params == '1' || params == '7') {
          _moveHome();
        } else if (params == '4' || params == '8') {
          _moveEnd();
        } else if (params == '3') {
          _delete();
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Editing operations
  // ---------------------------------------------------------------------------

  void _insert(String s) {
    _buffer.insert(_cursor, s);
    _cursor++;
    _resetHistoryNav();
    _refresh();
  }

  void _backspace() {
    if (_cursor == 0) return;
    _buffer.removeAt(_cursor - 1);
    _cursor--;
    _resetHistoryNav();
    _refresh();
  }

  void _delete() {
    if (_cursor >= _buffer.length) return;
    _buffer.removeAt(_cursor);
    _resetHistoryNav();
    _refresh();
  }

  void _moveLeft() {
    if (_cursor == 0) return;
    _cursor--;
    // A wrapped line's cursor may need to cross a row boundary, which a plain
    // `\x1b[D` can't do; the multi-row repaint repositions correctly.
    if (_width > 0) {
      _refresh();
      return;
    }
    _output('\x1b[D');
  }

  void _moveRight() {
    if (_cursor >= _buffer.length) return;
    _cursor++;
    if (_width > 0) {
      _refresh();
      return;
    }
    _output('\x1b[C');
  }

  void _moveHome() {
    if (_cursor == 0) return;
    if (_width > 0) {
      _cursor = 0;
      _refresh();
      return;
    }
    _output('\x1b[${_cursor}D');
    _cursor = 0;
  }

  void _moveEnd() {
    final right = _buffer.length - _cursor;
    if (right == 0) return;
    if (_width > 0) {
      _cursor = _buffer.length;
      _refresh();
      return;
    }
    _output('\x1b[${right}C');
    _cursor = _buffer.length;
  }

  // ---------------------------------------------------------------------------
  // Tab completion
  // ---------------------------------------------------------------------------

  /// Completes the word ending at the cursor by asking [_onComplete] for
  /// candidates. A unique candidate is inserted (with a trailing space unless it
  /// names a directory, i.e. ends in `/`); several candidates complete the
  /// longest common prefix, or are listed when no further prefix can be added.
  Future<void> _complete() async {
    final onComplete = _onComplete;
    if (onComplete == null || _promptCompleter != null) return;
    // The word is the run of characters from the previous space up to the
    // cursor; it is in command position when only spaces precede it.
    var start = _cursor;
    while (start > 0 && _buffer[start - 1] != ' ') {
      start--;
    }
    final word = _buffer.sublist(start, _cursor).join();
    final isCommand = _buffer.sublist(0, start).every((c) => c == ' ');

    // Pause input so keystrokes can't interleave with the in-flight round-trip.
    _sub?.pause();
    try {
      final candidates = await onComplete(word, isCommand);
      _applyCompletion(start, word, candidates);
    } on Object {
      // A failed completion is non-fatal; leave the line untouched.
    } finally {
      _sub?.resume();
    }
  }

  void _applyCompletion(int start, String word, List<String> candidates) {
    if (candidates.isEmpty) {
      _output('\x07'); // bell: nothing to complete
      return;
    }
    if (candidates.length == 1) {
      final only = candidates.first;
      _replaceWord(start, only, addSpace: !only.endsWith('/'));
      return;
    }
    final prefix = _longestCommonPrefix(candidates);
    if (prefix.length > word.length) {
      _replaceWord(start, prefix, addSpace: false);
    } else {
      _listCandidates(candidates);
    }
  }

  /// Replaces the buffer range `[start, _cursor)` with [replacement], optionally
  /// appending a space, then repaints.
  void _replaceWord(int start, String replacement, {required bool addSpace}) {
    final chars = _splitChars(replacement);
    if (addSpace) chars.add(' ');
    _buffer.replaceRange(start, _cursor, chars);
    _cursor = start + chars.length;
    _resetHistoryNav();
    _refresh();
  }

  /// Prints [candidates] on their own lines, then repaints the prompt and line.
  void _listCandidates(List<String> candidates) {
    _output('\r\n${candidates.join('  ')}\r\n');
    // The candidates moved the cursor to a fresh line; the old input rows are
    // now above it, so repaint fresh instead of clearing them.
    _resetRenderTracking();
    _refresh();
  }

  /// The longest common prefix shared by every entry of [items] (by character).
  static String _longestCommonPrefix(List<String> items) {
    if (items.isEmpty) return '';
    var prefix = _splitChars(items.first);
    for (final item in items.skip(1)) {
      final chars = _splitChars(item);
      var i = 0;
      final max = prefix.length < chars.length ? prefix.length : chars.length;
      while (i < max && prefix[i] == chars[i]) {
        i++;
      }
      prefix = prefix.sublist(0, i);
      if (prefix.isEmpty) break;
    }
    return prefix.join();
  }

  void _commit() {
    final line = _buffer.join();
    _output('\r\n');
    _buffer.clear();
    _cursor = 0;
    // The line is committed and the cursor is on a fresh row; forget the paint
    // so a later clear/repaint doesn't touch rows we no longer own.
    _resetRenderTracking();
    _resetHistoryNav();
    // A prompt is awaiting an answer: deliver the line to it, not as a command.
    final waiting = _promptCompleter;
    if (waiting != null) {
      _promptCompleter = null;
      waiting.complete(line);
      return;
    }
    _deliver(line);
  }

  void _interrupt() {
    _output('^C\r\n');
    _buffer.clear();
    _cursor = 0;
    _resetRenderTracking();
    _resetHistoryNav();
    // Cancel a pending prompt (treated as an empty answer) rather than firing the
    // session interrupt, so a command waiting on input is unblocked.
    final waiting = _promptCompleter;
    if (waiting != null) {
      _promptCompleter = null;
      waiting.complete('');
      return;
    }
    _onInterrupt?.call();
  }

  Future<void> _deliver(String line) async {
    // Mark a command in flight so stray keystrokes are ignored while it runs
    // (see [_onBytes]); a [prompt] it raises still lets the answer line through.
    _running = true;
    try {
      await _onLine(line);
    } finally {
      _running = false;
    }
  }

  // ---------------------------------------------------------------------------
  // History navigation
  // ---------------------------------------------------------------------------

  void _historyPrev() {
    // Stash the in-progress line and match on the text before the cursor (empty
    // means "browse all entries"); the cursor captures both on the first step.
    final text = _histCursor.up(
      line: _buffer.join(),
      prefix: _buffer.sublist(0, _cursor).join(),
    );
    if (text != null) _replaceLine(text);
  }

  void _historyNext() {
    final text = _histCursor.down();
    if (text != null) _replaceLine(text);
  }

  /// Resets history browsing so the next Up recomputes the prefix from the
  /// current input. Called after any edit to the line.
  void _resetHistoryNav() => _histCursor.reset();

  void _replaceLine(String text) {
    _buffer
      ..clear()
      ..addAll(_splitChars(text));
    _cursor = _buffer.length;
    _refresh();
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  /// Emits output via [emit] without disturbing the current input line.
  ///
  /// When a prompt is showing (interactive line mode, idle), it erases the
  /// current line first and repaints the prompt+buffer afterwards, so output
  /// arriving while the user is typing (e.g. a backgrounded job) appears above
  /// the input rather than tangled with it. During raw passthrough — when a
  /// remote program owns the screen — or in non-interactive mode it just runs
  /// [emit], leaving the bytes untouched.
  void printAbove(void Function() emit) {
    if (!interactive || _passthrough) {
      emit();
      return;
    }
    _clearInputLine();
    emit();
    _refresh();
  }

  /// Repaints the prompt and buffer, then positions the cursor. When the
  /// terminal [width] is known this clears and repaints across every wrapped
  /// row (see [_refreshMulti]); otherwise it falls back to a single-row repaint
  /// whose carriage-return + erase-line avoids needing the prompt's visible
  /// width — correct only while the line fits one row.
  void _refresh() {
    // While the idle prompt is hidden (the AI agent owns the screen), clear the
    // line but draw no prompt — unless a [prompt] question is pending, which
    // must always be visible so the user can answer it.
    if (_promptHidden && _promptCompleter == null) {
      _clearInputLine();
      return;
    }
    if (_width > 0) {
      _refreshMulti();
      return;
    }
    _output('\r\x1b[K$_prompt${_buffer.join()}');
    final right = _buffer.length - _cursor;
    if (right > 0) _output('\x1b[${right}D');
  }

  /// Repaints the prompt+buffer across the (possibly multiple) rows it wraps
  /// onto, then places the cursor at [_cursor]. Clears every row the previous
  /// paint used before redrawing, so a growing/shrinking line never staircases.
  ///
  /// The row math mirrors the battle-tested linenoise multi-line refresh: it
  /// tracks how many rows the last paint spanned ([_lastRows]) and where it left
  /// the cursor ([_lastPos]) so it can move to the bottom row, erase upward, and
  /// reprint. When the line ends exactly at the right margin it forces a newline
  /// to sidestep the terminal-dependent "pending wrap" cursor position (the
  /// reason otherwise-identical output can render differently across browsers).
  void _refreshMulti() {
    final cols = _width;
    final plen = _promptWidth;
    final len = _buffer.length;
    final pos = _cursor;
    final out = StringBuffer();

    // Rows the current content needs (ceil), and the row (1-based) the cursor
    // sat on in the previous paint.
    var rows = (plen + len + cols - 1) ~/ cols;
    final rpos = ((plen + _lastPos) ~/ cols) + 1;

    // Move down to the last row of the previous paint, then erase each row from
    // the bottom up, ending on the top (prompt) row.
    if (_lastRows - rpos > 0) out.write('\x1b[${_lastRows - rpos}B');
    for (var j = 0; j < _lastRows - 1; j++) {
      out.write('\r\x1b[K\x1b[1A');
    }
    out.write('\r\x1b[K');

    // Repaint prompt + buffer.
    out
      ..write(_prompt)
      ..write(_buffer.join());

    if (pos == len) {
      // The cursor is already at the natural end of what we just printed, so no
      // reposition is needed — except at the exact-width boundary, where the
      // cursor is in pending-wrap limbo; a newline drops it onto a definite
      // fresh row (and avoids the terminal-dependent pending-wrap difference).
      if ((plen + len) > 0 && (plen + len) % cols == 0) {
        out.write('\n\r');
        rows++;
      }
    } else {
      // Mid-line cursor: move up from the bottom row to its row, then its column.
      final rpos2 = ((plen + pos) ~/ cols) + 1;
      if (rows - rpos2 > 0) out.write('\x1b[${rows - rpos2}A');
      final col = (plen + pos) % cols;
      out.write(col > 0 ? '\r\x1b[${col}C' : '\r');
    }

    _lastPos = pos;
    _lastRows = rows;
    _output(out.toString());
  }

  /// Erases the input line the editor last painted (all wrapped rows) and leaves
  /// the cursor at the top-left of where the prompt began. Falls back to a
  /// single-row erase when the width is unknown.
  void _clearInputLine() {
    if (_width <= 0) {
      _output('\r\x1b[K');
      _resetRenderTracking();
      return;
    }
    final cols = _width;
    final rpos = ((_promptWidth + _lastPos) ~/ cols) + 1;
    final out = StringBuffer();
    if (_lastRows - rpos > 0) out.write('\x1b[${_lastRows - rpos}B');
    for (var j = 0; j < _lastRows - 1; j++) {
      out.write('\r\x1b[K\x1b[1A');
    }
    out.write('\r\x1b[K');
    _resetRenderTracking();
    _output(out.toString());
  }

  /// Forgets the last paint's row/cursor bookkeeping. Called after output that
  /// moved the cursor to a fresh line (a committed line, printed candidates, a
  /// full-screen takeover) so the next repaint starts clean.
  void _resetRenderTracking() {
    _lastRows = 0;
    _lastPos = 0;
  }

  /// The visible column width of [text]: rune count with ANSI CSI escapes (e.g.
  /// the prompt's SGR color codes) removed. One column per rune.
  static int _visibleWidth(String text) {
    final runes = text.runes.toList();
    var width = 0;
    var i = 0;
    while (i < runes.length) {
      if (runes[i] == 0x1b) {
        i++;
        if (i < runes.length && runes[i] == 0x5b) {
          // CSI: skip params/intermediates up to and including the final byte.
          i++;
          while (i < runes.length && !(runes[i] >= 0x40 && runes[i] <= 0x7e)) {
            i++;
          }
          if (i < runes.length) i++;
        }
        continue;
      }
      width++;
      i++;
    }
    return width;
  }

  /// Splits [text] into user-visible characters (Unicode runes as strings).
  static List<String> _splitChars(String text) =>
      text.runes.map(String.fromCharCode).toList();
}

enum _ParseState { normal, esc, csi }
