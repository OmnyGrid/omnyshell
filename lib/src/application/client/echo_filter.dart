import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// Removes a shell's echo of the command lines the client sends it.
///
/// Windows PowerShell reading commands from a redirected stdin (as a pipe
/// session does) writes each line it reads back to stdout before running it.
/// The init line silences the prompt but not that echo, so without this the
/// user would see every command — with its marker tail — repeated above its
/// output. Until the init line has run, the echo even follows PowerShell's
/// default prompt (`PS C:\…> `), and an unfinished statement's continuation
/// lines follow `>> `.
///
/// [expect] queues each line as it is sent. [filter] drops an output line
/// that is a queued line — alone, or after such a prompt — with its line
/// terminator, along with any lines queued before it (their echo was missed).
/// Everything else passes through.
///
/// To recognise an echo split across chunks, a trailing partial line that
/// could still become one is held back — but only while the shell is seen to
/// echo: a shell that did not echo during the last command ([commandCompleted]
/// with lines still pending; PowerShell 7 may not echo) gets its output
/// passed on at once, still checked line by line, until an echo shows up
/// again.
class EchoFilter {
  final Queue<List<int>> _pending = Queue();
  Uint8List _held = Uint8List(0);
  bool _echoing = true;
  bool _echoSeenThisCommand = false;

  /// Whether a trailing partial line may be held back as a possible echo:
  /// the shell has been seen to echo (or nothing tells otherwise yet).
  bool get holdsPartialLines => _echoing;

  /// Queues [line] (as sent, without its newline) as an echo to expect.
  void expect(String line) => _pending.add(utf8.encode(line));

  /// A command completed (its marker arrived): its lines' echoes, if any, have
  /// been seen by now. Forgets those still pending — when none was echoed,
  /// the shell is taken not to echo, and partial lines stop being held.
  ///
  /// Returns any bytes held back, which then belong to the output. Call it
  /// before sending the next lines, which belong to the next command.
  Uint8List commandCompleted() {
    if (_pending.isNotEmpty && !_echoSeenThisCommand) _echoing = false;
    _pending.clear();
    _echoSeenThisCommand = false;
    final held = _held;
    _held = Uint8List(0);
    return held;
  }

  /// [chunk] with the echoes of the expected lines removed.
  Uint8List filter(Uint8List chunk) {
    if (_pending.isEmpty && _held.isEmpty) return chunk;
    final buf = _held.isEmpty
        ? chunk
        : (BytesBuilder(copy: false)
                ..add(_held)
                ..add(chunk))
              .takeBytes();
    _held = Uint8List(0);

    final out = BytesBuilder(copy: false);
    var start = 0;
    while (start < buf.length) {
      final newline = buf.indexOf(0x0a, start);
      if (newline < 0) {
        // A partial line: hold it if it may still grow into an echo.
        final rest = Uint8List.sublistView(buf, start);
        if (_echoing && _pending.isNotEmpty && _mayBecomeEcho(rest)) {
          _held = Uint8List.fromList(rest);
        } else {
          out.add(rest);
        }
        break;
      }
      final contentEnd = newline > start && buf[newline - 1] == 0x0d
          ? newline - 1
          : newline;
      final line = Uint8List.sublistView(buf, start, contentEnd);
      if (!_consumeEcho(line)) {
        out.add(Uint8List.sublistView(buf, start, newline + 1));
      }
      start = newline + 1;
    }
    return out.takeBytes();
  }

  /// Whether [line] (without its terminator) is the echo of a queued line,
  /// alone or after a PowerShell prompt; if so, dequeues it and the lines
  /// queued before it.
  bool _consumeEcho(Uint8List line) {
    if (_pending.isEmpty) return false;
    var index = 0;
    for (final echo in _pending) {
      if (_isEcho(line, echo)) {
        for (var k = 0; k <= index; k++) {
          _pending.removeFirst();
        }
        _echoing = true;
        _echoSeenThisCommand = true;
        return true;
      }
      index++;
    }
    return false;
  }

  /// [line] is [echo], or [echo] after a prompt ([_isPrompt]).
  static bool _isEcho(Uint8List line, List<int> echo) {
    if (line.length < echo.length) return false;
    final offset = line.length - echo.length;
    for (var j = 0; j < echo.length; j++) {
      if (line[offset + j] != echo[j]) return false;
    }
    return offset == 0 || _isPrompt(Uint8List.sublistView(line, 0, offset));
  }

  /// PowerShell's default prompt (`PS <location>> `) or its continuation
  /// prompt (`>> `).
  static bool _isPrompt(Uint8List text) {
    final s = latin1.decode(text);
    return s == '>> ' || (s.startsWith('PS ') && s.endsWith('> '));
  }

  /// Whether the partial line [rest] could still become an echo: a prefix
  /// of a queued line, or a PowerShell prompt so far (with or without the
  /// start of an echo after it). A program's own `> ` prompt is not held: it
  /// must show while the program waits for input.
  bool _mayBecomeEcho(Uint8List rest) {
    final s = latin1.decode(rest);
    if (s.startsWith('PS ') || s == '>' || s.startsWith('>> ')) return true;
    for (final echo in _pending) {
      final n = rest.length < echo.length ? rest.length : echo.length;
      var prefix = rest.length <= echo.length + 1; // + a possible CR
      for (var j = 0; prefix && j < n; j++) {
        if (rest[j] != echo[j]) prefix = false;
      }
      if (prefix && (rest.length <= echo.length || rest.last == 0x0d)) {
        return true;
      }
    }
    return false;
  }
}
