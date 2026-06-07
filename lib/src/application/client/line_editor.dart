import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../shared/utils/omnyshell_home.dart';

/// Persistent, per-key command history backed by a plain-text file.
///
/// Each key (typically `<user>@<node>`) maps to its own file under
/// `<home>/.omnyshell/history/<key>.history`, so connecting to different nodes
/// or as different principals never mixes histories. The home directory
/// resolves from `OMNYSHELL_HOME`, then `HOME`, then `USERPROFILE` — the same
/// convention used by the credential store.
class CommandHistory {
  /// Newest entry last. Bounded to [maxEntries].
  final List<String> _entries;

  /// Backing file, or `null` for an in-memory-only history (e.g. in tests).
  final File? _file;

  /// Upper bound on retained entries; oldest are dropped first.
  final int maxEntries;

  CommandHistory._(this._entries, this._file, this.maxEntries);

  /// Loads the history for [key], returning an empty history when no file
  /// exists yet. Pass [home] to override the base directory (used by tests).
  static Future<CommandHistory> load({
    required String key,
    String? home,
    int maxEntries = 1000,
  }) async {
    final file = File(_path(key, home));
    var entries = <String>[];
    try {
      if (await file.exists()) {
        entries = (await file.readAsLines())
            .where((l) => l.trim().isNotEmpty)
            .toList();
        if (entries.length > maxEntries) {
          entries = entries.sublist(entries.length - maxEntries);
        }
      }
    } on Object {
      // A corrupt or unreadable history file must never break the shell.
      entries = <String>[];
    }
    return CommandHistory._(entries, file, maxEntries);
  }

  /// An in-memory history with no backing file (used by tests).
  factory CommandHistory.inMemory({
    List<String>? entries,
    int maxEntries = 1000,
  }) => CommandHistory._(entries ?? <String>[], null, maxEntries);

  /// The entries, oldest first. The returned list is a copy.
  List<String> get entries => List.unmodifiable(_entries);

  /// Records [entry], skipping blank lines and consecutive duplicates, then
  /// persists the (trimmed-to-cap) history. IO failures are swallowed so the
  /// interactive session is never interrupted by a disk error.
  Future<void> add(String entry) async {
    if (entry.trim().isEmpty) return;
    if (_entries.isNotEmpty && _entries.last == entry) return;
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    await _persist();
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
      await file.writeAsString('${_entries.join('\n')}\n');
      await _chmod(file.path, '600');
    } on Object {
      // Best-effort persistence only.
    }
  }

  static String _path(String key, String? home) =>
      omnyshellPath(['history', '${sanitizeKey(key)}.history'], home: home);

  /// Maps an arbitrary key to a safe, stable filename component.
  static String sanitizeKey(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_.@-]'), '_');
    return safe.isEmpty ? '_' : safe;
  }

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
/// - Up / Down walk backward / forward through [history].
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

  StreamSubscription<Object?>? _sub;
  bool _closed = false;

  // --- Editing state (interactive mode only) ---
  String _prompt = '';
  final List<String> _buffer = []; // one entry per user-visible character
  int _cursor = 0;

  // History navigation: index into _history.entries, or == length when editing
  // a fresh line. [_stash] holds the fresh line set aside while browsing.
  int _histIndex = 0;
  String _stash = '';

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
  }) : _input = input,
       _output = output,
       _onLine = onLine,
       _history = history,
       _setRawMode = setRawMode,
       _onInterrupt = onInterrupt,
       _onEof = onEof {
    _histIndex = _history.entries.length;
  }

  /// Records [line] in the history (subject to [CommandHistory.add] rules) and
  /// resets the navigation cursor to the newest entry.
  Future<void> addHistory(String line) async {
    await _history.add(line);
    _histIndex = _history.entries.length;
    _stash = '';
  }

  /// Updates the prompt shown before the input and repaints the current line.
  void setPrompt(String prompt) {
    _prompt = prompt;
    if (interactive) _refresh();
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
    _refresh();
  }

  void _backspace() {
    if (_cursor == 0) return;
    _buffer.removeAt(_cursor - 1);
    _cursor--;
    _refresh();
  }

  void _delete() {
    if (_cursor >= _buffer.length) return;
    _buffer.removeAt(_cursor);
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

  void _commit() {
    final line = _buffer.join();
    _output('\r\n');
    _buffer.clear();
    _cursor = 0;
    _histIndex = _history.entries.length;
    _stash = '';
    _deliver(line);
  }

  void _interrupt() {
    _output('^C\r\n');
    _buffer.clear();
    _cursor = 0;
    _histIndex = _history.entries.length;
    _stash = '';
    _onInterrupt?.call();
  }

  Future<void> _deliver(String line) async {
    // Pause input while the handler runs so keystrokes can't interleave with an
    // in-flight command (e.g. a confirmation prompt awaiting the next line).
    _sub?.pause();
    try {
      await _onLine(line);
    } finally {
      _sub?.resume();
    }
  }

  // ---------------------------------------------------------------------------
  // History navigation
  // ---------------------------------------------------------------------------

  void _historyPrev() {
    final entries = _history.entries;
    if (_histIndex == 0) return;
    if (_histIndex == entries.length) _stash = _buffer.join();
    _histIndex--;
    _replaceLine(entries[_histIndex]);
  }

  void _historyNext() {
    final entries = _history.entries;
    if (_histIndex >= entries.length) return;
    _histIndex++;
    _replaceLine(_histIndex == entries.length ? _stash : entries[_histIndex]);
  }

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
