import 'dart:convert';
import 'dart:typed_data';

import '../../shared/utils/id_generator.dart';

/// The outcome of feeding one chunk of remote stdout to a [CwdMarker].
///
/// [output] is the clean process output to forward to the user (with any marker
/// line removed); the remaining fields carry the state reported by a marker that
/// completed within this chunk (the last one if several did), or `null` if none
/// did or the field was empty.
class CwdScan {
  /// Process output to forward, with marker lines stripped.
  final Uint8List output;

  /// The current working directory, if a marker completed in this chunk.
  final String? cwd;

  /// The git branch of the remote cwd, or `null` when it is not a git repo.
  final String? branch;

  /// Compact git status (`+staged ~modified ?untracked`), or `null` when clean
  /// or not a git repo.
  final String? gitStatus;

  /// Privilege label (`root`) when the remote session is the superuser, else
  /// `null`.
  final String? privilege;

  /// Creates a scan result.
  const CwdScan(
    this.output,
    this.cwd, [
    this.branch,
    this.gitStatus,
    this.privilege,
  ]);
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
  ///
  /// The marker line carries tab-separated fields after the token: `$PWD`, the
  /// git branch (empty outside a repo), a compact status (`+staged ~modified
  /// ?untracked`, empty when clean), and a privilege label (`root` when euid 0).
  /// Git branch names cannot contain tabs or spaces, so `\t` is a safe delimiter.
  /// Inline command substitution is used so the remote shell's environment is
  /// not polluted; the raw-string parts keep Dart from interpreting the shell's
  /// `$`, `\`, and quotes.
  String get command {
    final mid = token.length ~/ 2;
    final a = token.substring(0, mid);
    final b = token.substring(mid);
    const pwd = r'"$PWD"';
    const branch = r'"$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"';
    const status =
        r'''"$(git status --porcelain 2>/dev/null | awk 'BEGIN{s=0;m=0;u=0}/^\?\?/{u++;next}{if(substr($0,1,1)!=" ")s++;if(substr($0,2,1)!=" ")m++}END{if(s+m+u>0)printf "+%d ~%d ?%d",s,m,u}')"''';
    const priv = r'''"$([ "$(id -u 2>/dev/null)" = 0 ] && echo root)"''';
    return "printf '%s%s%s\\t%s\\t%s\\t%s\\n' '$a' '$b' $pwd $branch $status $priv";
  }

  /// Feeds a chunk of remote stdout, returning clean output and any cwd found.
  CwdScan feed(Uint8List chunk) {
    _buffer.addAll(chunk);
    final output = BytesBuilder(copy: false);
    String? cwd;
    String? branch;
    String? gitStatus;
    String? privilege;

    final tokenBytes = utf8.encode(token);
    while (true) {
      final start = _indexOf(_buffer, tokenBytes);
      if (start < 0) break;
      final newline = _buffer.indexOf(0x0a, start + tokenBytes.length);
      if (newline < 0) break; // marker not yet terminated; wait for more bytes.
      output.add(Uint8List.fromList(_buffer.sublist(0, start)));
      // On a real PTY the kernel's ONLCR translates the marker's trailing `\n`
      // into `\r\n`; drop that `\r` so it is not captured as part of the last
      // field (otherwise an empty privilege field becomes "\r", whose carriage
      // return corrupts the rendered prompt).
      final fieldsStart = start + tokenBytes.length;
      final fieldsEnd = (newline > fieldsStart && _buffer[newline - 1] == 0x0d)
          ? newline - 1
          : newline;
      final fieldBytes = _buffer.sublist(fieldsStart, fieldsEnd);
      final fields = utf8.decode(fieldBytes, allowMalformed: true).split('\t');
      cwd = fields[0];
      branch = _field(fields, 1);
      gitStatus = _field(fields, 2);
      privilege = _field(fields, 3);
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

    return CwdScan(output.takeBytes(), cwd, branch, gitStatus, privilege);
  }

  /// Returns the trimmed field at [index], or `null` if absent or empty.
  static String? _field(List<String> fields, int index) {
    if (index >= fields.length) return null;
    final value = fields[index];
    return value.isEmpty ? null : value;
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
