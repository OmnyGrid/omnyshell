import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// Removes PowerShell's prompts and its echo of the command lines the client
/// sends it.
///
/// PowerShell (Windows PowerShell 5.1 and PowerShell 7 alike) reading its
/// commands from a redirected stdin, as a pipe session does, writes its prompt
/// before reading each line, then echoes the line it read, ending with `\n`:
///
/// ```text
/// PS C:\Users\u> function prompt { '' }; …\n     ← the init line, before it ran
/// PS>$__omnyLc=$LASTEXITCODE;…\n                 ← empty prompt: "PS>" fallback
/// <marker output>\n
/// PS>Write-Output hi ; [Console]::Out.Write(…)\n ← a command, echoed
/// hi\r\n
/// <marker output>\n
/// PS>                                             ← waiting for the next line
/// ```
///
/// (recorded from both editions by `test/integration/powershell_pipe_test`).
/// Without this the user would see every command — with its marker tail —
/// repeated above its output, and `PS>` before it.
///
/// [expect] queues each line as it is sent. [filter] drops an output line that
/// is a queued line after a prompt (`PS>`, the default `PS <location>> `, the
/// continuation `>> `) or alone, along with any lines queued before it (their
/// echo was missed). Everything else passes through.
///
/// A prompt is written *before* the next line is even sent, so a line start
/// that is (or may become) a prompt is held back until its line completes —
/// across command boundaries too ([commandCompleted]): it is never shown.
/// A partial line that may become an echo without a prompt is held only
/// while the shell is seen to echo (see [holdsPartialLines]).
class EchoFilter {
  final Queue<List<int>> _pending = Queue();
  Uint8List _held = Uint8List(0);
  bool _lineStart = true;
  bool _echoing = true;
  bool _echoSeenThisCommand = false;

  /// Whether a partial line that may become an echo without a prompt is held
  /// back: the shell has been seen to echo (or nothing tells otherwise yet).
  /// A shell that did not echo the last command gets such output passed on at
  /// once, until an echo shows up again.
  bool get holdsPartialLines => _echoing;

  /// Queues [line] (as sent, without its newline) as an echo to expect.
  void expect(String line) => _pending.add(utf8.encode(line));

  /// A command completed (its marker arrived): its lines' echoes, if any, have
  /// been seen by now. Forgets those still pending — when none was echoed,
  /// the shell is taken not to echo.
  ///
  /// Returns the bytes held back that are output after all. A held prompt is
  /// kept: it is PowerShell waiting for the next line, whose echo will follow
  /// it. Call this before sending the next lines, which belong to the next
  /// command.
  Uint8List commandCompleted() {
    if (_pending.isNotEmpty && !_echoSeenThisCommand) _echoing = false;
    _pending.clear();
    _echoSeenThisCommand = false;
    if (_held.isEmpty || _isPromptSoFar(latin1.decode(_held))) {
      return Uint8List(0);
    }
    final held = _held;
    _held = Uint8List(0);
    _lineStart = false;
    return held;
  }

  /// [chunk] with the prompts and the echoes of the expected lines removed.
  Uint8List filter(Uint8List chunk) {
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
        final rest = Uint8List.sublistView(buf, start);
        if (_lineStart && _mayBecomeEcho(rest)) {
          _held = Uint8List.fromList(rest);
        } else {
          out.add(rest);
          _lineStart = false;
        }
        break;
      }
      final contentEnd = newline > start && buf[newline - 1] == 0x0d
          ? newline - 1
          : newline;
      final line = Uint8List.sublistView(buf, start, contentEnd);
      if (!(_lineStart && _consumeEcho(line))) {
        out.add(Uint8List.sublistView(buf, start, newline + 1));
      }
      _lineStart = true;
      start = newline + 1;
    }
    return out.takeBytes();
  }

  /// Whether [line] (without its terminator) is the echo of a queued line,
  /// after a prompt or alone; if so, dequeues it and the lines queued before.
  bool _consumeEcho(Uint8List line) {
    if (_pending.isEmpty) return false;
    final prompt = _promptLength(latin1.decode(line));
    final body = prompt > 0 ? Uint8List.sublistView(line, prompt) : line;
    var index = 0;
    for (final echo in _pending) {
      if (_same(body, echo)) {
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

  /// Whether the partial line [rest], at a line start, may still become a
  /// prompt and echo: a prompt so far (or the start of one), a prompt then
  /// the start of a queued line, or — while the shell echoes — the start of a
  /// queued line alone. A program's own `> ` prompt is not one: it must show
  /// while the program waits for input.
  bool _mayBecomeEcho(Uint8List rest) {
    final s = latin1.decode(rest);
    if (_isPromptSoFar(s)) return true;
    final prompt = _promptLength(s);
    if (prompt > 0) {
      return _prefixOfPending(Uint8List.sublistView(rest, prompt));
    }
    return _echoing && _prefixOfPending(rest);
  }

  bool _prefixOfPending(Uint8List text) {
    for (final echo in _pending) {
      // The echo itself, then possibly its CR.
      if (text.length > echo.length + 1) continue;
      final n = text.length < echo.length ? text.length : echo.length;
      var match = true;
      for (var j = 0; match && j < n; j++) {
        if (text[j] != echo[j]) match = false;
      }
      if (match && (text.length <= echo.length || text.last == 0x0d)) {
        return true;
      }
    }
    return false;
  }

  /// The length of the PowerShell prompt [s] starts with — `PS>`, `>> `, or
  /// `PS <location>> ` — or 0 when it starts with none.
  static int _promptLength(String s) {
    if (s.startsWith('PS>')) return 3;
    if (s.startsWith('>> ')) return 3;
    if (s.startsWith('PS ')) {
      final end = s.indexOf('> ', 3);
      if (end > 0) return end + 2;
    }
    return 0;
  }

  /// Whether [s] is a whole prompt, or could still grow into one.
  static bool _isPromptSoFar(String s) {
    if (s.isEmpty) return false;
    if ('PS>'.startsWith(s) || '>> '.startsWith(s)) return true;
    final prompt = _promptLength(s);
    if (prompt == s.length) return true;
    // The default prompt's location is still arriving.
    return prompt == 0 && s.startsWith('PS ') && s.length < 1024;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
