import 'dart:io';

/// An editable in-memory text buffer for one file: a list of [lines], a caret
/// at ([cursorRow], [cursorCol]), edit operations, a [dirty] flag and load/save
/// against the local filesystem.
///
/// Columns are measured in UTF-16 code units (the natural unit for Dart string
/// slicing); this is exact for the ASCII-heavy source the IDE targets. All edit
/// methods keep the caret within bounds and set [dirty] when they change text.
class TextDocument {
  TextDocument._(
    this.path,
    this._lines, {
    required this.eol,
    required this.hadFinalNewline,
    required this.isBinary,
  });

  /// Builds an in-memory document from [lines] (used by tests and new buffers).
  factory TextDocument.fromLines(
    List<String> lines, {
    String path = '',
    String eol = '\n',
    bool hadFinalNewline = true,
  }) => TextDocument._(
    path,
    lines.isEmpty ? [''] : List.of(lines),
    eol: eol,
    hadFinalNewline: hadFinalNewline,
    isBinary: false,
  );

  /// The absolute or display path of the file (empty for an unsaved scratch
  /// buffer).
  final String path;

  final List<String> _lines;

  /// The line ending used when saving (`\n` or `\r\n`), detected on load.
  final String eol;

  /// Whether the file ended with a trailing newline (preserved on save).
  final bool hadFinalNewline;

  /// Whether the file looked binary (contained NUL bytes); such buffers are
  /// opened read-only.
  final bool isBinary;

  int cursorRow = 0;
  int cursorCol = 0;

  /// The column the caret "wants" during vertical movement, so moving down then
  /// up returns to the original column even across short lines.
  int _goalCol = 0;

  bool _dirty = false;

  /// Whether the buffer has unsaved edits.
  bool get dirty => _dirty;

  /// An unmodifiable view of the lines.
  List<String> get lines => List.unmodifiable(_lines);

  /// The number of lines.
  int get lineCount => _lines.length;

  /// The text of line [row] (empty when out of range).
  String lineAt(int row) => row >= 0 && row < _lines.length ? _lines[row] : '';

  /// Loads the file at [path] from disk, detecting its line ending and whether
  /// it is binary. A missing file yields an empty buffer.
  static TextDocument load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return TextDocument.fromLines([''], path: path);
    }
    final bytes = file.readAsBytesSync();
    final isBinary = bytes.contains(0);
    final content = String.fromCharCodes(bytes);
    final crlf = content.contains('\r\n');
    final normalised = content.replaceAll('\r\n', '\n');
    final hadFinalNewline = normalised.endsWith('\n');
    final body = hadFinalNewline && normalised.isNotEmpty
        ? normalised.substring(0, normalised.length - 1)
        : normalised;
    final lines = body.split('\n');
    return TextDocument._(
      path,
      lines.isEmpty ? [''] : lines,
      eol: crlf ? '\r\n' : '\n',
      hadFinalNewline: hadFinalNewline || content.isEmpty,
      isBinary: isBinary,
    );
  }

  /// The buffer serialised back to text, with the detected EOL and trailing
  /// newline (when the original had one).
  String toText() {
    final body = _lines.join(eol);
    return hadFinalNewline ? '$body$eol' : body;
  }

  /// Writes the buffer to [path] (or its own [path]) and clears [dirty].
  void save({String? toPath}) {
    final target = toPath ?? path;
    File(target).writeAsStringSync(toText());
    _dirty = false;
  }

  // ---- Cursor movement -----------------------------------------------------

  /// Places the caret at ([row], [col]), clamped into range, and resets the
  /// vertical goal column to match. Use this for absolute positioning (e.g.
  /// jumping to a location); the directional `move*` methods preserve the goal
  /// column instead.
  void moveTo(int row, int col) {
    if (_lines.isEmpty) _lines.add('');
    cursorRow = row.clamp(0, _lines.length - 1);
    cursorCol = col.clamp(0, _lines[cursorRow].length);
    _goalCol = cursorCol;
  }

  /// Moves the caret one column left, wrapping to the end of the previous line.
  void moveLeft() {
    if (cursorCol > 0) {
      cursorCol--;
    } else if (cursorRow > 0) {
      cursorRow--;
      cursorCol = _lines[cursorRow].length;
    }
    _goalCol = cursorCol;
  }

  /// Moves the caret one column right, wrapping to the start of the next line.
  void moveRight() {
    if (cursorCol < _lines[cursorRow].length) {
      cursorCol++;
    } else if (cursorRow < _lines.length - 1) {
      cursorRow++;
      cursorCol = 0;
    }
    _goalCol = cursorCol;
  }

  /// Moves the caret up one line, keeping the goal column.
  void moveUp() {
    if (cursorRow == 0) {
      cursorCol = 0;
      _goalCol = 0;
      return;
    }
    cursorRow--;
    cursorCol = _goalCol.clamp(0, _lines[cursorRow].length);
  }

  /// Moves the caret down one line, keeping the goal column.
  void moveDown() {
    if (cursorRow >= _lines.length - 1) {
      cursorCol = _lines[cursorRow].length;
      _goalCol = cursorCol;
      return;
    }
    cursorRow++;
    cursorCol = _goalCol.clamp(0, _lines[cursorRow].length);
  }

  /// Moves the caret to the start of the line.
  void moveHome() {
    cursorCol = 0;
    _goalCol = 0;
  }

  /// Moves the caret to the end of the line.
  void moveEnd() {
    cursorCol = _lines[cursorRow].length;
    _goalCol = cursorCol;
  }

  /// Moves the caret up by [rows] lines (page up).
  void movePageUp(int rows) {
    cursorRow = (cursorRow - rows).clamp(0, _lines.length - 1);
    cursorCol = _goalCol.clamp(0, _lines[cursorRow].length);
  }

  /// Moves the caret down by [rows] lines (page down).
  void movePageDown(int rows) {
    cursorRow = (cursorRow + rows).clamp(0, _lines.length - 1);
    cursorCol = _goalCol.clamp(0, _lines[cursorRow].length);
  }

  // ---- Editing -------------------------------------------------------------

  /// Inserts printable [text] (no newlines) at the caret, advancing it.
  void insert(String text) {
    if (isBinary || text.isEmpty) return;
    final line = _lines[cursorRow];
    _lines[cursorRow] =
        line.substring(0, cursorCol) + text + line.substring(cursorCol);
    cursorCol += text.length;
    _goalCol = cursorCol;
    _dirty = true;
  }

  /// Splits the current line at the caret (Enter), moving onto the new line.
  void insertNewline() {
    if (isBinary) return;
    final line = _lines[cursorRow];
    final before = line.substring(0, cursorCol);
    final after = line.substring(cursorCol);
    _lines[cursorRow] = before;
    _lines.insert(cursorRow + 1, after);
    cursorRow++;
    cursorCol = 0;
    _goalCol = 0;
    _dirty = true;
  }

  /// Deletes the character before the caret (Backspace), joining lines at a
  /// line start.
  void backspace() {
    if (isBinary) return;
    if (cursorCol > 0) {
      final line = _lines[cursorRow];
      _lines[cursorRow] =
          line.substring(0, cursorCol - 1) + line.substring(cursorCol);
      cursorCol--;
    } else if (cursorRow > 0) {
      final prev = _lines[cursorRow - 1];
      final cur = _lines[cursorRow];
      cursorCol = prev.length;
      _lines[cursorRow - 1] = prev + cur;
      _lines.removeAt(cursorRow);
      cursorRow--;
    } else {
      return;
    }
    _goalCol = cursorCol;
    _dirty = true;
  }

  /// Deletes the character at the caret (Delete), joining the next line at a
  /// line end.
  void deleteForward() {
    if (isBinary) return;
    final line = _lines[cursorRow];
    if (cursorCol < line.length) {
      _lines[cursorRow] =
          line.substring(0, cursorCol) + line.substring(cursorCol + 1);
    } else if (cursorRow < _lines.length - 1) {
      _lines[cursorRow] = line + _lines[cursorRow + 1];
      _lines.removeAt(cursorRow + 1);
    } else {
      return;
    }
    _goalCol = cursorCol;
    _dirty = true;
  }
}
