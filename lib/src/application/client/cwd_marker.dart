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

  /// The exit code of the command that preceded a completed [CwdMarker.command]
  /// when it was emitted by the exit-code-carrying [CwdMarker.agentCommand]
  /// (an extra 5th marker field). `null` for the regular cwd/ping markers, which
  /// do not report it.
  final int? exitCode;

  /// Creates a scan result.
  const CwdScan(
    this.output,
    this.cwd, [
    this.branch,
    this.gitStatus,
    this.privilege,
    this.completed = false,
    this.exitCode,
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

  /// A per-session string distinct from [token] (which the marker scan looks
  /// for), that the PowerShell dialect makes its prompt: PowerShell writes its
  /// prompt before every line it reads, and this lets the client strip it — and
  /// the echoed line after it — exactly (see `EchoFilter`).
  String get promptSentinel => token.replaceFirst('_CWD_', '_PS_');

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
  /// not polluted, except for the one unexported variable that caches the
  /// privilege; the raw-string parts keep Dart from interpreting the shell's
  /// `$`, `\`, and quotes.
  String get command {
    final (a, b) = tokenHalves;
    return "printf '%s%s%s\\t%s\\t%s\\n' '$a' '$b' "
        '$_pwd $_git $_priv';
  }

  /// Like [command], but also reports the exit code of the command that ran just
  /// before it as a 5th tab field, used by the AI agent to detect failures when
  /// it runs a command in the interactive session.
  ///
  /// `$?` is saved into a variable *first* (before the `$(git …)` substitutions
  /// clobber it) and emitted as the trailing field.
  String get agentCommand {
    final (a, b) = tokenHalves;
    return r"__omny_ec=$?; "
        "printf '%s%s%s\\t%s\\t%s\\t%s\\n' '$a' '$b' "
        '$_pwd $_git $_priv "\$__omny_ec"';
  }

  static const _pwd = r'"$PWD"';

  /// The branch and status fields from one git process. `-b` heads the
  /// porcelain output with `## <branch>[...<upstream>] [ahead N]`,
  /// `## No commits yet on <branch>` (`Initial commit on` before git 2.17) or
  /// `## HEAD (no branch)` when detached. awk prints `<branch>\t<status>`
  /// (just the tab outside a repo, or without git) so the field count holds.
  ///
  /// `git status` needs a work tree; inside `.git/` or a bare repo it fails,
  /// and only then `git rev-parse --abbrev-ref HEAD` (which needs none) names
  /// the branch, as a `## ` header for the same awk.
  static const _git =
      r'''"$({ git status --porcelain -b 2>/dev/null || { __omny_b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) && printf '## %s\n' "$__omny_b"; }; } | awk 'BEGIN{b="";s=0;m=0;u=0}/^## /{b=substr($0,4);sub(/^(No commits yet|Initial commit) on /,"",b);sub(/\.\.\..*/,"",b);sub(/ .*/,"",b);next}/^\?\?/{u++;next}{if(substr($0,1,1)!=" ")s++;if(substr($0,2,1)!=" ")m++}END{printf "%s\t",b;if(s+m+u>0)printf "+%d ~%d ?%d",s,m,u}')"''';

  /// The privilege field, resolved by the first marker of a session and cached
  /// in `__omny_pv` (`${var=…}` runs `id` only while it is unset). Unexported,
  /// so a nested `su`/`sudo -s` shell resolves its own.
  static const _priv =
      r'''"${__omny_pv=$([ "$(id -u 2>/dev/null)" = 0 ] && echo root)}"''';

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
    int? exitCode;
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
      // winpty may also return the cursor to column 0 before the CRLF
      // (`<token>\r\r\n`), leaving a stray `\r` that would otherwise turn a ping
      // into a cwd of "\r". The fields never legitimately contain an ESC or a
      // carriage return, so drop both.
      final fieldText = _stripAnsi(
        utf8.decode(
          _buffer.sublist(fieldsStart, fieldsEnd),
          allowMalformed: true,
        ),
      ).replaceAll('\r', '');
      // A ping marker carries no fields (just the token, possibly wrapped in the
      // PTY's escapes); after stripping it is empty, so it only signals
      // completion and leaves the cached cwd/git state untouched.
      if (fieldText.isNotEmpty) {
        final fields = fieldText.split('\t');
        cwd = fields[0];
        branch = _field(fields, 1);
        gitStatus = _field(fields, 2);
        privilege = _field(fields, 3);
        final ec = _field(fields, 4);
        if (ec != null) exitCode = int.tryParse(ec);
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
      exitCode,
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
