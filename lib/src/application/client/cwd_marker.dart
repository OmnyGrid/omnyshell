import 'dart:convert';
import 'dart:typed_data';

import '../../shared/utils/id_generator.dart';

/// The outcome of feeding one chunk of remote stdout to a [CwdMarker].
///
/// [output] is the clean process output to forward to the user (with any marker
/// line removed); [cwd] is the working directory reported by a marker that
/// completed within this chunk, or `null` if none did.
class CwdScan {
  /// Process output to forward, with marker lines stripped.
  final Uint8List output;

  /// The current working directory, if a marker completed in this chunk.
  final String? cwd;

  /// Creates a scan result.
  const CwdScan(this.output, this.cwd);
}

/// Client-side shell integration that learns the remote working directory.
///
/// The interactive `connect` loop has no PTY, so the remote shell prints no
/// prompt and there is no command-completion signal. After each forwarded
/// command this marker's [command] is enqueued on the remote stdin; the shell
/// runs it once the command finishes and emits a single line carrying `$PWD`.
/// [feed] scans the live stdout stream for that line, strips it from the output,
/// and surfaces the parsed directory — which also tells the caller when to
/// redraw the prompt.
///
/// The detection [token] is a random nonce, but [command] splits it across two
/// `printf` arguments so the literal command text we send never contains the
/// full token. This avoids false matches when an interactive program (e.g.
/// `cat`) echoes the marker line back verbatim.
class CwdMarker {
  /// The full token emitted by the marker line and searched for in output.
  final String token;

  final List<int> _buffer = [];

  /// Creates a marker, using a random [nonce] by default.
  CwdMarker([String? nonce]) : token = '__OMNYSHELL_CWD_${nonce ?? newId()}__';

  /// The shell command (without trailing newline) to enqueue after a command.
  ///
  /// Splitting [token] into two `printf` args keeps the full token out of the
  /// literal command text while still emitting it intact at runtime.
  String get command {
    final mid = token.length ~/ 2;
    final a = token.substring(0, mid);
    final b = token.substring(mid);
    return "printf '%s%s%s\\n' '$a' '$b' \"\$PWD\"";
  }

  /// Feeds a chunk of remote stdout, returning clean output and any cwd found.
  CwdScan feed(Uint8List chunk) {
    _buffer.addAll(chunk);
    final output = BytesBuilder(copy: false);
    String? cwd;

    final tokenBytes = utf8.encode(token);
    while (true) {
      final start = _indexOf(_buffer, tokenBytes);
      if (start < 0) break;
      final newline = _buffer.indexOf(0x0a, start + tokenBytes.length);
      if (newline < 0) break; // marker not yet terminated; wait for more bytes.
      output.add(Uint8List.fromList(_buffer.sublist(0, start)));
      final pathBytes = _buffer.sublist(start + tokenBytes.length, newline);
      cwd = utf8.decode(pathBytes, allowMalformed: true);
      _buffer.removeRange(0, newline + 1);
    }

    // Retain only the longest buffer suffix that could start a split token, so
    // partial tokens are never leaked but normal output is not held back.
    final keep = _tokenPrefixSuffix(_buffer, tokenBytes);
    if (_buffer.length > keep) {
      final flush = _buffer.length - keep;
      output.add(Uint8List.fromList(_buffer.sublist(0, flush)));
      _buffer.removeRange(0, flush);
    }

    return CwdScan(output.takeBytes(), cwd);
  }

  /// The length of the longest suffix of [buffer] that is a prefix of [token].
  static int _tokenPrefixSuffix(List<int> buffer, List<int> token) {
    final max = buffer.length < token.length - 1
        ? buffer.length
        : token.length - 1;
    for (var k = max; k > 0; k--) {
      var match = true;
      for (var j = 0; j < k; j++) {
        if (buffer[buffer.length - k + j] != token[j]) {
          match = false;
          break;
        }
      }
      if (match) return k;
    }
    return 0;
  }

  static int _indexOf(List<int> haystack, List<int> needle) {
    if (needle.isEmpty) return -1;
    final last = haystack.length - needle.length;
    for (var i = 0; i <= last; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}
