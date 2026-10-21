import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// Removes a shell's echo of the command lines the client sends it.
///
/// Windows PowerShell reading commands from a redirected stdin (as a pipe
/// session does) writes each line it reads back to stdout before running it.
/// The init line silences the prompt but not that echo, so without this the
/// user would see every command — with its marker tail — repeated above its
/// output.
///
/// [expect] queues each line as it is sent. [filter] then drops the first
/// occurrence of the next queued line that starts an output line, with its
/// line terminator, and passes everything else through. Bytes that could
/// still turn out to be an echo are held until they can be told apart, so an
/// echo split across chunks is still recognised.
///
/// A shell that does not echo (PowerShell 7 may not) is detected: when a
/// command completes ([commandCompleted]) and none of the lines sent for it
/// was echoed, the filter turns itself off for the session, and so never
/// delays output there.
class EchoFilter {
  final Queue<List<int>> _pending = Queue();
  List<int> _held = const [];
  bool _atLineStart = true;
  bool _seenEcho = false;
  bool _disabled = false;

  /// Whether the filter has concluded the shell does not echo.
  bool get disabled => _disabled;

  /// Queues [line] (as sent, without its newline) as an echo to expect.
  void expect(String line) {
    if (_disabled) return;
    _pending.add(utf8.encode(line));
  }

  /// A command completed (its marker arrived): its lines' echoes, if any, have
  /// been seen by now. Forgets those still pending — and, if no echo was ever
  /// seen, concludes the shell does not echo.
  ///
  /// Returns any bytes held back, which then belong to the output.
  Uint8List commandCompleted() {
    if (!_seenEcho && _pending.isNotEmpty) _disabled = true;
    _pending.clear();
    final held = Uint8List.fromList(_held);
    _held = const [];
    return held;
  }

  /// [chunk] with the echoes of the expected lines removed. Bytes that may be
  /// the start of an echo are kept back for the next call (or
  /// [commandCompleted]).
  Uint8List filter(Uint8List chunk) {
    if (_disabled || (_pending.isEmpty && _held.isEmpty)) {
      if (chunk.isNotEmpty) _atLineStart = chunk.last == 0x0a;
      return chunk;
    }
    final buf = [..._held, ...chunk];
    _held = const [];
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < buf.length) {
      if (_atLineStart && _pending.isNotEmpty) {
        switch (_matchEcho(buf, i, _pending.first)) {
          case final int end when end > 0:
            // An echo: drop it and its line terminator.
            _pending.removeFirst();
            _seenEcho = true;
            i = end;
            continue;
          case -1:
            // Could still be an echo: wait for more.
            _held = buf.sublist(i);
            return out.takeBytes();
          default:
            break; // not an echo
        }
      }
      // Pass this line (or what there is of it) through.
      final newline = buf.indexOf(0x0a, i);
      final stop = newline < 0 ? buf.length : newline + 1;
      out.add(buf.sublist(i, stop));
      _atLineStart = newline >= 0;
      i = stop;
    }
    return out.takeBytes();
  }

  /// Whether [buf] at [start] holds [echo] and its line terminator (`\n` or
  /// `\r\n`): the index past it; `-1` when it is only a prefix so far; `0`
  /// when it is not that echo.
  static int _matchEcho(List<int> buf, int start, List<int> echo) {
    final available = buf.length - start;
    final n = available < echo.length ? available : echo.length;
    for (var j = 0; j < n; j++) {
      if (buf[start + j] != echo[j]) return 0;
    }
    if (available <= echo.length) return -1;
    var k = start + echo.length;
    if (buf[k] == 0x0d) {
      k++;
      if (k == buf.length) return -1;
    }
    return buf[k] == 0x0a ? k + 1 : 0;
  }
}
