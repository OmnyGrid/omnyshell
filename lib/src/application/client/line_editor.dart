import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../shared/utils/omnyshell_home.dart';
import 'command_history.dart';

/// Persistent, per-key command history backed by a plain-text file.
///
/// Each key (typically `<user>@<node>`) maps to its own file under
/// `<home>/.omnyshell/history/<key>.history`, so connecting to different nodes
/// or as different principals never mixes histories. The home directory
/// resolves from `OMNYSHELL_HOME`, then `HOME`, then `USERPROFILE` — the same
/// convention used by the credential store.
class CommandHistory {
  /// The shared, storage-agnostic entry buffer (add rules + cap + migration).
  final CommandHistoryBuffer _buffer;

  /// Backing file, or `null` for an in-memory-only history (e.g. in tests).
  final File? _file;

  CommandHistory._(this._buffer, this._file);

  /// Upper bound on retained entries; oldest are dropped first.
  int get maxEntries => _buffer.maxEntries;

  /// Loads the history for [key], returning an empty history when no file
  /// exists yet. Pass [home] to override the base directory (used by tests).
  static Future<CommandHistory> load({
    required String key,
    String? home,
    int maxEntries = 1000,
  }) async {
    final file = File(_path(key, home));
    final buffer = CommandHistoryBuffer(maxEntries: maxEntries);
    try {
      if (await file.exists()) {
        buffer.replaceAll(
          (await file.readAsLines()).where((l) => l.trim().isNotEmpty),
        );
      }
    } on Object {
      // A corrupt or unreadable history file must never break the shell.
    }
    return CommandHistory._(buffer, file);
  }

  /// An in-memory history with no backing file (used by tests).
  factory CommandHistory.inMemory({
    List<String>? entries,
    int maxEntries = 1000,
  }) => CommandHistory._(
    CommandHistoryBuffer(entries: entries, maxEntries: maxEntries),
    null,
  );

  /// The entries, oldest first. The returned list is a copy.
  List<String> get entries => _buffer.entries;

  /// Records [entry], skipping blank lines and consecutive duplicates, then
  /// persists the (trimmed-to-cap) history. IO failures are swallowed so the
  /// interactive session is never interrupted by a disk error.
  Future<void> add(String entry) async {
    if (_buffer.add(entry)) await _persist();
  }

  Future<void> _persist() async {
    final file = _file;
    if (file == null) return;
    try {
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        await _chmod(dir.path, '700');
      }
      await file.writeAsString('${_buffer.entries.join('\n')}\n');
      await _chmod(file.path, '600');
    } on Object {
      // Best-effort persistence only.
    }
  }

  /// Copies the history recorded under [fromKey] into [toKey], placing the
  /// migrated entries before any already present under [toKey] (consecutive
  /// duplicates are collapsed at the splice boundary). The [fromKey] file is
  /// left intact as a backup. A no-op when the source is missing or empty.
  ///
  /// Used when a node's UID changes: the caller migrates the prior UID's
  /// history into the new UID's history after the user opts in.
  static Future<void> migrate({
    required String fromKey,
    required String toKey,
    String? home,
    int maxEntries = 1000,
  }) async {
    final from = await load(key: fromKey, home: home, maxEntries: maxEntries);
    if (from.entries.isEmpty) return;
    final to = await load(key: toKey, home: home, maxEntries: maxEntries);
    to._buffer.prepend(from.entries.toList());
    await to._persist();
  }

  static String _path(String key, String? home) =>
      omnyshellPath(['history', '${sanitizeKey(key)}.history'], home: home);

  /// Maps an arbitrary key to a safe, stable filename component.
  static String sanitizeKey(String key) =>
      CommandHistoryBuffer.sanitizeKey(key);

  /// A fresh Up/Down navigation cursor over this history's entries.
  HistoryCursor cursor() => HistoryCursor(_buffer);

  static Future<void> _chmod(String path, String mode) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', [mode, path]);
    } on Object {
      // Permission hardening is best-effort.
    }
  }
}

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
/// Note: the editor assumes the visible line fits on a single terminal row;
/// inputs long enough to wrap may not repaint perfectly.
class LineEditor {
  final Stream<List<int>> _input;
  final void Function(String) _output;
  final FutureOr<void> Function(String line) _onLine;
  final bool interactive;
  final CommandHistory _history;
  final void Function(bool raw)? _setRawMode;
  final void Function()? _onInterrupt;
  final void Function()? _onEof;
  final void Function(List<int> bytes)? _onRaw;
  final Future<List<String>> Function(String word, bool isCommand)? _onComplete;

  StreamSubscription<Object?>? _sub;
  bool _closed = false;

  // When true, incoming bytes bypass the line-edit state machine entirely and
  // are forwarded verbatim to [_onRaw]. Used while a full-screen remote app
  // (e.g. nano/vim) owns the terminal, so its keystrokes reach it unmodified.
  bool _passthrough = false;

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
    required CommandHistory history,
    this.interactive = true,
    void Function(bool raw)? setRawMode,
    void Function()? onInterrupt,
    void Function()? onEof,
    void Function(List<int> bytes)? onRaw,
    Future<List<String>> Function(String word, bool isCommand)? onComplete,
  }) : _input = input,
       _output = output,
       _onLine = onLine,
       _history = history,
       _setRawMode = setRawMode,
       _onInterrupt = onInterrupt,
       _onEof = onEof,
       _onRaw = onRaw,
       _onComplete = onComplete {
    _histCursor = _history.cursor();
  }

  /// Records [line] in the history (subject to [CommandHistory.add] rules) and
  /// resets the navigation cursor to the newest entry.
  Future<void> addHistory(String line) async {
    await _history.add(line);
    _histCursor.reset();
  }

  /// Updates the prompt shown before the input and repaints the current line.
  void setPrompt(String prompt) {
    _prompt = prompt;
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
  }

  /// Handles a Ctrl-C that arrived out-of-band (raw mode keeps `ISIG` enabled,
  /// so the terminal raises `SIGINT` instead of delivering a `0x03` byte).
  ///
  /// In line mode it discards the current input, echoes `^C`, and notifies
  /// `onInterrupt`. In passthrough mode a full-screen app owns the screen, so it
  /// only notifies `onInterrupt` (which relays the signal to the remote app).
  void interrupt() {
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
    _output('\x1b[D');
  }

  void _moveRight() {
    if (_cursor >= _buffer.length) return;
    _cursor++;
    _output('\x1b[C');
  }

  void _moveHome() {
    if (_cursor == 0) return;
    _output('\x1b[${_cursor}D');
    _cursor = 0;
  }

  void _moveEnd() {
    final right = _buffer.length - _cursor;
    if (right == 0) return;
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
    _output('\r\x1b[K');
    emit();
    _refresh();
  }

  /// Repaints the prompt and buffer on the current row, then positions the
  /// cursor. Carriage-return + erase-line avoids needing the prompt's visible
  /// width (which may include ANSI color codes).
  void _refresh() {
    _output('\r\x1b[K$_prompt${_buffer.join()}');
    final right = _buffer.length - _cursor;
    if (right > 0) _output('\x1b[${right}D');
  }

  /// Splits [text] into user-visible characters (Unicode runes as strings).
  static List<String> _splitChars(String text) =>
      text.runes.map(String.fromCharCode).toList();
}

enum _ParseState { normal, esc, csi }
