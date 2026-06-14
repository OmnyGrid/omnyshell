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

  /// Whether a marker (full or ping) terminated in this chunk — i.e. the remote
  /// command finished and the shell is back at its prompt. A ping sets this
  /// without populating [cwd]/[branch]/… so the client can repaint the prompt in
  /// the right place (after the command's output) while keeping its cached state.
  final bool completed;

  /// Creates a scan result.
  const CwdScan(
    this.output,
    this.cwd, [
    this.branch,
    this.gitStatus,
    this.privilege,
    this.completed = false,
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

  /// The [token] split into two halves, for emitting it across two literal
  /// arguments so the full token never appears verbatim in the command text we
  /// send (which would false-match if an interactive program echoed it back).
  /// Shared by every [ShellDialect] that builds its own marker command.
  (String, String) get tokenHalves {
    final mid = token.length ~/ 2;
    return (token.substring(0, mid), token.substring(mid));
  }

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
    final (a, b) = tokenHalves;
    const pwd = r'"$PWD"';
    const branch = r'"$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"';
    const status =
        r'''"$(git status --porcelain 2>/dev/null | awk 'BEGIN{s=0;m=0;u=0}/^\?\?/{u++;next}{if(substr($0,1,1)!=" ")s++;if(substr($0,2,1)!=" ")m++}END{if(s+m+u>0)printf "+%d ~%d ?%d",s,m,u}')"''';
    const priv = r'''"$([ "$(id -u 2>/dev/null)" = 0 ] && echo root)"''';
    return "printf '%s%s%s\\t%s\\t%s\\t%s\\n' '$a' '$b' $pwd $branch $status $priv";
  }

  /// A lightweight completion marker (without trailing fields) to enqueue after
  /// commands that cannot change the prompt's cwd/git state.
  ///
  /// It emits only the [token] (split across two `printf` args, like [command]),
  /// so the client learns the command finished — and can repaint the prompt
  /// after its output — without paying for the `git` queries [command] runs.
  String get pingCommand {
    final (a, b) = tokenHalves;
    return "printf '%s%s\\n' '$a' '$b'";
  }

  /// Feeds a chunk of remote stdout, returning clean output and any cwd found.
  CwdScan feed(Uint8List chunk) {
    _buffer.addAll(chunk);
    final output = BytesBuilder(copy: false);
    String? cwd;
    String? branch;
    String? gitStatus;
    String? privilege;
    var completed = false;

    final tokenBytes = utf8.encode(token);
    int? pendingStart; // start of a found-but-unterminated token, if any.
    while (true) {
      final start = _indexOf(_buffer, tokenBytes);
      if (start < 0) break;
      final newline = _buffer.indexOf(0x0a, start + tokenBytes.length);
      if (newline < 0) {
        // A complete token is present but its terminating newline has not
        // arrived yet (e.g. winpty scraped the console mid-line, splitting the
        // marker from its `\n`). Retain from the token start so it is not
        // leaked; a later feed() completes it. Without this the token body is
        // flushed to the user and the completion signal is lost.
        pendingStart = start;
        break;
      }
      output.add(Uint8List.fromList(_buffer.sublist(0, start)));
      // On a real PTY the kernel's ONLCR translates the marker's trailing `\n`
      // into `\r\n`; drop that `\r` so it is not captured as part of the last
      // field (otherwise an empty privilege field becomes "\r", whose carriage
      // return corrupts the rendered prompt).
      final fieldsStart = start + tokenBytes.length;
      final fieldsEnd = (newline > fieldsStart && _buffer[newline - 1] == 0x0d)
          ? newline - 1
          : newline;
      completed = true;
      // A real Windows PTY (winpty) renders the marker line through a console
      // scraper that injects VT escape sequences around the fields and before
      // the `\r\n` — erase-line (`\x1b[K`) and cursor show/hide (`\x1b[?25h/l`).
      // Strip every escape from the field region so they never pollute the cwd
      // (a polluted cwd later fails TAB-completion's `chdir`) or other fields.
      // The fields themselves never legitimately contain an ESC.
      final fieldText = _stripAnsi(
        utf8.decode(
          _buffer.sublist(fieldsStart, fieldsEnd),
          allowMalformed: true,
        ),
      );
      // A ping marker carries no fields (just the token, possibly wrapped in the
      // PTY's escapes); after stripping it is empty, so it only signals
      // completion and leaves the cached cwd/git state untouched.
      if (fieldText.isNotEmpty) {
        final fields = fieldText.split('\t');
        cwd = fields[0];
        branch = _field(fields, 1);
        gitStatus = _field(fields, 2);
        privilege = _field(fields, 3);
      }
      _buffer.removeRange(0, newline + 1);
    }

    if (pendingStart != null) {
      // Flush everything before the unterminated token; keep the token (and any
      // partial fields) until its newline arrives.
      if (pendingStart > 0) {
        output.add(Uint8List.fromList(_buffer.sublist(0, pendingStart)));
        _buffer.removeRange(0, pendingStart);
      }
    } else {
      // Retain only the longest buffer suffix that could start a split token, so
      // partial tokens are never leaked but normal output is not held back.
      final keep = _tokenPrefixSuffix(_buffer, tokenBytes);
      if (_buffer.length > keep) {
        final flush = _buffer.length - keep;
        output.add(Uint8List.fromList(_buffer.sublist(0, flush)));
        _buffer.removeRange(0, flush);
      }
    }

    return CwdScan(
      output.takeBytes(),
      cwd,
      branch,
      gitStatus,
      privilege,
      completed,
    );
  }

  /// Matches the ANSI/VT escape sequences a console-scraping PTY (winpty) injects
  /// into the marker line: CSI sequences (colors `\x1b[0m`, erase-line `\x1b[K`,
  /// cursor visibility `\x1b[?25h/l`, cursor moves) and OSC strings (`\x1b]…BEL`).
  static final RegExp _ansi = RegExp(
    r'\x1b\[[0-?]*[ -/]*[@-~]' // CSI: ESC [ params intermediates final
    r'|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', // OSC: ESC ] … (BEL | ST)
  );

  /// Removes ANSI/VT escape sequences from [s]. A fast path skips the regex when
  /// there is no ESC byte at all (the common, non-PTY case).
  static String _stripAnsi(String s) =>
      s.contains('\x1b') ? s.replaceAll(_ansi, '') : s;

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
