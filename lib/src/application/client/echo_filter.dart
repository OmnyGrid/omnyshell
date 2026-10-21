import 'dart:convert';
import 'dart:typed_data';

/// Removes PowerShell's prompts, and its echo of the lines it reads, from a
/// session's output.
///
/// PowerShell (Windows PowerShell 5.1 and PowerShell 7 alike) reading its
/// commands from a redirected stdin, as a pipe session does, writes its prompt
/// before reading each line, then echoes the line it read, ending with `\n`
/// (recorded by `test/integration/powershell_pipe_test`):
///
/// ```text
/// PS C:\Users\u> function prompt { … }; …\n  ← the init line, before it ran
/// <prompt>$__omnyLc=$LASTEXITCODE;…\n        ← the first marker, echoed
/// <marker output>\n
/// <prompt>Write-Output hi ; [Console]::Out…\n ← a command, echoed
/// hi\r\n
/// <marker output>\n
/// <prompt>                                    ← waiting for the next line
/// ```
///
/// The session's init line makes `<prompt>` a per-session sentinel
/// (`CwdMarker.promptSentinel`, written in two halves so it never appears in
/// the init line's own echo). Every line PowerShell reads, then, comes back as
/// one output line starting with that exact string: the filter drops each such
/// line whole — whoever sent what PowerShell read (the client's commands and
/// markers, keystrokes typed ahead, continuation lines). Nothing else is
/// touched: a program's own prompt (a nested `pwsh`'s `PS C:\…> `, a REPL's
/// `>`) shows as it is.
///
/// The one line before the sentinel exists — the init line's echo, after the
/// default `PS <location>> ` prompt — is dropped by its known text.
///
/// A prompt is written before the next line is even sent, so a line start
/// that is, or may still become, the sentinel is held back until its line
/// completes; nothing else is ever held.
class EchoFilter {
  /// Filters the output of a session whose prompt is [prompt] (the
  /// sentinel), and whose first line read is [initLine] (the line that sets
  /// that prompt; `null` when the session was set up earlier).
  EchoFilter({required String prompt, String? initLine})
    : _prompt = utf8.encode(prompt),
      _initLine = initLine == null ? null : utf8.encode(initLine);

  final Uint8List _prompt;

  /// The init line's echo to drop, until it has been (or the init line has
  /// otherwise taken effect).
  Uint8List? _initLine;

  Uint8List _held = Uint8List(0);
  bool _lineStart = true;

  static final _defaultPrompt = latin1.encode('PS ');

  /// A command completed: the init line has run by now, so the default
  /// prompt is no longer expected.
  void commandCompleted() => _initLine = null;

  /// [chunk] without PowerShell's prompts and the lines echoed after them.
  /// Bytes that may still become a prompt are held for the next call.
  Uint8List filter(Uint8List chunk) {
    if (_held.isEmpty && _initLine == null && !_promptMayStartIn(chunk)) {
      if (chunk.isNotEmpty) _lineStart = chunk.last == 0x0a;
      return chunk;
    }
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
        if (_lineStart && _mayBecomeDropped(rest)) {
          _held = Uint8List.fromList(rest);
        } else {
          out.add(rest);
          _lineStart = false;
        }
        break;
      }
      if (!(_lineStart && _isDropped(buf, start, newline))) {
        out.add(Uint8List.sublistView(buf, start, newline + 1));
      }
      _lineStart = true;
      start = newline + 1;
    }
    return out.takeBytes();
  }

  /// Whether the line `buf[start..newline]` is a prompt and what PowerShell
  /// read after it, or the init line's echo.
  bool _isDropped(Uint8List buf, int start, int newline) {
    if (_startsWith(buf, start, newline, _prompt)) {
      _initLine = null; // the sentinel prompt: the init line has run
      return true;
    }
    final init = _initLine;
    if (init != null && _startsWith(buf, start, newline, _defaultPrompt)) {
      final end = newline > start && buf[newline - 1] == 0x0d
          ? newline - 1
          : newline;
      if (_endsWith(buf, start, end, init)) {
        _initLine = null;
        return true;
      }
    }
    return false;
  }

  /// Whether the partial line [rest] may still become a dropped line: the
  /// sentinel so far, the sentinel and what follows, or — before the init
  /// line has run — the default prompt so far.
  bool _mayBecomeDropped(Uint8List rest) {
    if (_startsWith(rest, 0, rest.length, _prompt) ||
        _isPrefix(rest, _prompt)) {
      return true;
    }
    return _initLine != null &&
        (_startsWith(rest, 0, rest.length, _defaultPrompt) ||
            _isPrefix(rest, _defaultPrompt)) &&
        rest.length < 4096;
  }

  /// Whether a line of [chunk] (the first, if a line starts at the chunk's
  /// start) begins with the sentinel's first byte: the cheap test that lets a
  /// chunk with no prompt pass through without being copied.
  bool _promptMayStartIn(Uint8List chunk) {
    final first = _prompt[0];
    if (_lineStart && chunk.isNotEmpty && chunk[0] == first) return true;
    for (var i = 0; i < chunk.length - 1; i++) {
      if (chunk[i] == 0x0a && chunk[i + 1] == first) return true;
    }
    return false;
  }

  /// Whether `buf[start..end)` starts with [prefix].
  static bool _startsWith(Uint8List buf, int start, int end, List<int> prefix) {
    if (end - start < prefix.length) return false;
    for (var j = 0; j < prefix.length; j++) {
      if (buf[start + j] != prefix[j]) return false;
    }
    return true;
  }

  /// Whether `buf[start..end)` ends with [suffix].
  static bool _endsWith(Uint8List buf, int start, int end, List<int> suffix) {
    if (end - start < suffix.length) return false;
    final offset = end - suffix.length;
    for (var j = 0; j < suffix.length; j++) {
      if (buf[offset + j] != suffix[j]) return false;
    }
    return true;
  }

  /// Whether [part] (non-empty) is a proper prefix of [whole].
  static bool _isPrefix(Uint8List part, List<int> whole) {
    if (part.isEmpty || part.length >= whole.length) return false;
    for (var j = 0; j < part.length; j++) {
      if (part[j] != whole[j]) return false;
    }
    return true;
  }
}
