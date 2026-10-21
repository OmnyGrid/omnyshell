import '../../domain/backend/shell_family.dart';
import 'cwd_marker.dart';

/// Generates the shell-specific text the interactive `connect`/`resume` loop
/// sends to a remote shell: a one-time init line, the per-command wrapper, and
/// the prompt-completion markers.
///
/// The *parsing* of marker output is shell-agnostic and stays in [CwdMarker];
/// only the emitted command syntax differs per [ShellFamily]. Each marker emits
/// the same line format the parser expects — the token immediately followed by
/// `cwd`, then tab-separated `branch`, `status` and `priv` fields:
///
/// ```
/// <token><cwd>\t<branch>\t<status>\t<priv>\n
/// ```
///
/// A *ping* marker emits just `<token>\n` (no fields) to signal completion
/// without re-querying git state.
abstract class ShellDialect {
  const ShellDialect();

  /// Returns the dialect for [family].
  static ShellDialect forFamily(ShellFamily family) => switch (family) {
    ShellFamily.posix => const PosixShellDialect(),
    ShellFamily.powershell => const PowerShellDialect(),
    ShellFamily.cmd => const CmdShellDialect(),
  };

  /// A single command sent once when the session opens (e.g. installing a
  /// Ctrl-C trap or suppressing the shell's prompt), or `null` if none.
  String? get initLine;

  /// The [initLine] for the session [marker] belongs to — the line the client
  /// actually sends. The same as [initLine] unless the dialect ties it to the
  /// session (PowerShell's prompt sentinel).
  String? sessionInitLine(CwdMarker marker) => initLine;

  /// The full marker command: reports cwd plus git branch/status and privilege.
  String fullMarker(CwdMarker marker);

  /// The lightweight ping marker: signals completion only (no git queries).
  String pingMarker(CwdMarker marker);

  /// A marker that also reports the preceding command's exit code (used when the
  /// AI agent runs a command in the interactive session). POSIX and PowerShell
  /// carry the exit code; `cmd` falls back to [fullMarker], so its exit code is
  /// unknown.
  String agentMarker(CwdMarker marker) => fullMarker(marker);

  /// The AI agent's [line] prepared to run before an [agentMarker] (state the
  /// marker needs to tell the line's exit code). Unchanged by default.
  String agentLine(String line) => line;

  /// Whether the shell writes a prompt and each command line it reads back to
  /// stdout (see `EchoFilter`), so the client must drop them.
  bool get echoesInput => false;

  /// Wraps a user-typed [line] so it runs and is followed by [tail] (a marker)
  /// as one logical unit. [interactive] enables terminal-echo handling where the
  /// dialect needs it (POSIX only: no tty echo to toggle over a pipe;
  /// PowerShell's own prompt and echo of the line are filtered instead, see
  /// [echoesInput]).
  String wrapCommand(
    String line, {
    required bool interactive,
    required String tail,
  });

  /// A command, in this dialect, that prints TAB-completion candidates for
  /// [word] — one per line, each a full replacement for the typed word (so it
  /// includes whatever was typed), with directories suffixed `/` so the editor
  /// can avoid appending a trailing space.
  ///
  /// When [isCommand] is true and [word] has no path separator, the word is in
  /// command position and completes against executables on `$PATH` (plus the
  /// shell's own builtins/cmdlets where natural); otherwise it globs paths.
  ///
  /// Run as a one-off `exec` on the node, in the matching shell family (see
  /// `resolveShellInvocation`'s `shellFamily` hint), so the snippet's syntax is
  /// understood and `$PATH`/cwd match the interactive session.
  String completionCommand(String word, {required bool isCommand});

  /// A command, in this dialect, that lists a directory including hidden
  /// entries and with human-readable sizes (the `ls -alh` equivalent). [args]
  /// is the raw text typed after the shortcut (paths, extra flags), appended
  /// verbatim; empty lists the current directory.
  String listCommand(String args);

  /// Expands the client-side `l` shortcut: a line whose first word is `l`
  /// becomes [listCommand] with the rest of the line as its arguments. Any
  /// other line is returned unchanged.
  String expandShortcut(String line) {
    final match = _listShortcut.firstMatch(line);
    if (match == null) return line;
    return listCommand(match.group(1)?.trim() ?? '');
  }
}

/// `l`, optionally followed by whitespace and arguments.
final RegExp _listShortcut = RegExp(r'^\s*l(?:\s+(.*))?$', dotAll: true);

/// POSIX shells (`sh`, `bash`, `zsh`, Git Bash, WSL): the original protocol,
/// unchanged. Uses `trap`, `eval`, `stty` and a `printf`/`git`/`id` marker.
class PosixShellDialect extends ShellDialect {
  const PosixShellDialect();

  // A no-op INT trap keeps the non-interactive shell alive when Ctrl-C
  // interrupts the foreground command.
  @override
  String? get initLine => "trap ':' INT";

  @override
  String fullMarker(CwdMarker marker) => marker.command;

  @override
  String pingMarker(CwdMarker marker) => marker.pingCommand;

  @override
  String agentMarker(CwdMarker marker) => marker.agentCommand;

  @override
  String wrapCommand(
    String line, {
    required bool interactive,
    required String tail,
  }) {
    // Run the command and the marker as one logical line (`eval` keeps this
    // valid for pipes, trailing `&`, `cd`…) so a foreground app consumes both
    // and the marker fires right after it exits.
    final escaped = line.replaceAll("'", r"'\''");
    final body = "eval '$escaped' ; $tail";
    // The remote shell runs with `stty -echo`; re-enable echo just for the
    // command so cooked-mode readers (read/cat/y-N) echo runtime input, then
    // disable it again before the marker.
    return interactive
        ? 'stty echo 2>/dev/null ; $body ; stty -echo 2>/dev/null'
        : body;
  }

  // Portable POSIX `sh` (no `bash`-only `compgen`), so it works regardless of
  // the node's login shell. Candidates complete by longest-common-prefix.
  @override
  String completionCommand(String word, {required bool isCommand}) {
    final w = _posixSingleQuote(word);
    // Glob `<word>*`, marking directories with a trailing slash. `"$w"*` keeps
    // the typed prefix literal (handles spaces/special chars) while globbing.
    const fileGlob =
        r'for p in "$w"*; do [ -e "$p" ] || continue; '
        r'if [ -d "$p" ]; then printf "%s/\n" "$p"; '
        r'else printf "%s\n" "$p"; fi; done';
    if (!isCommand) {
      return 'w=$w; $fileGlob';
    }
    // Command position: a word with a slash is a path; otherwise scan $PATH for
    // executables and print their basenames, sorted and de-duplicated.
    const pathScan =
        r'IFS=:; for d in $PATH; do [ -d "$d" ] || continue; '
        r'for p in "$d"/"$w"*; do [ -f "$p" ] && [ -x "$p" ] && '
        r'printf "%s\n" "${p##*/}"; done; done | sort -u';
    return 'w=$w; case "\$w" in */*) $fileGlob ;; *) $pathScan ;; esac';
  }

  // GNU (Linux, Git Bash, WSL) and BSD (macOS) `ls` both accept `-alh`.
  @override
  String listCommand(String args) => args.isEmpty ? 'ls -alh' : 'ls -alh $args';
}

/// Quotes [s] as a single POSIX shell word so it is taken literally.
String _posixSingleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// PowerShell (`pwsh`/`powershell`). The shell reads commands from a
/// redirected stdin, writing its prompt before each line it reads and then
/// echoing the line (both editions; see `EchoFilter`). The session's init line
/// ([sessionInitLine]) makes that prompt a per-session sentinel the client
/// strips exactly, with the echo after it ([echoesInput]). The marker computes
/// git status counts and the admin flag in PowerShell and writes one line
/// directly to the console out.
class PowerShellDialect extends ShellDialect {
  const PowerShellDialect();

  // Continue past non-terminating errors; an empty prompt function. Without a
  // session to tie it to, this cannot set the sentinel prompt the client
  // strips — and PowerShell shows an empty prompt as `PS>` — so the client
  // sends [sessionInitLine] instead.
  @override
  String? get initLine =>
      r"function prompt { '' }; $ErrorActionPreference='Continue'";

  /// [initLine] with the prompt made [CwdMarker.promptSentinel] — written as
  /// two concatenated halves, so the echo of this very line does not contain
  /// it. The client then strips the prompt, and the echoed line after it, by
  /// that exact string.
  @override
  String sessionInitLine(CwdMarker marker) {
    final sentinel = marker.promptSentinel;
    final mid = sentinel.length ~/ 2;
    return "function prompt { '${sentinel.substring(0, mid)}'+"
        "'${sentinel.substring(mid)}' }; "
        r"$ErrorActionPreference='Continue'";
  }

  /// PowerShell reading a redirected stdin writes its prompt before every
  /// line it reads, then echoes the line.
  @override
  bool get echoesInput => true;

  @override
  String fullMarker(CwdMarker marker) => _marker(marker, exitCode: false);

  @override
  String agentMarker(CwdMarker marker) => _marker(marker, exitCode: true);

  /// Clears `$LASTEXITCODE` just before the agent's line, after saving it, so
  /// the agent marker can tell a native program's code (set again) from a
  /// failed cmdlet (left unset), rather than reading an earlier program's
  /// stale code. The marker puts the saved value back when the line set none.
  @override
  String agentLine(String line) =>
      r'$__omnyLcPrev=$LASTEXITCODE;$global:LASTEXITCODE=$null;' + line;

  /// The full marker, with the preceding command's exit code as a 5th field
  /// when [exitCode] is set (the PowerShell counterpart of
  /// [CwdMarker.agentCommand]).
  String _marker(CwdMarker marker, {required bool exitCode}) {
    final (a, b) = marker.tokenHalves;
    // `$LASTEXITCODE` is saved first and restored last, so the user still sees
    // their own command's code rather than the marker's `git status` (0, or 128
    // outside a repo). Unset before (no native program has run yet), the one
    // git created is removed. `$?` is read-only and cannot be restored.
    const saveLc = r'$__omnyLc=$LASTEXITCODE;';
    const restoreLc =
        r';if($null -ne $__omnyLc){$global:LASTEXITCODE=$__omnyLc}'
        r'else{Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore}';
    // The agent's exit code: `$?` is captured before anything else (even an
    // assignment resets it). It says whether the command succeeded (any kind).
    // [agentLine] cleared `$LASTEXITCODE` before the line, so on failure a
    // non-zero value is a native program's code. Anything else reports 1: none
    // (a failed cmdlet), and 0 too — a line can fail after a program in it
    // succeeded (`git fetch; Get-Item nope`), and Windows PowerShell 5.1 fails
    // a program that wrote to stderr under `2>&1` even when it exits 0. With
    // none, the user's previous value is the one restored.
    const saveOk = r'$__omnyOk=$?;';
    const ec =
        r'$__omnyEc=if($__omnyOk){0}elseif($__omnyLc){$__omnyLc}'
        r'else{1};if($null -eq $__omnyLc){$__omnyLc=$__omnyLcPrev};';
    // Compute the fields in PowerShell: branch via git, status counts mirror the
    // POSIX awk (+staged ~modified ?untracked), privilege = 'root' when elevated.
    // Unset fields are $null so they render as empty (matching the POSIX marker).
    //
    // What cannot change during a session is resolved by the first marker and
    // cached in globals, so later markers skip the lookup:
    // - `$__omnyGit`: whether git exists. It is optional on a node, and calling
    //   a missing command raises a CommandNotFoundException that `2>$null` does
    //   not silence. `-ErrorAction Ignore` leaves no record in `$Error`.
    // - `$__omnyPv`: 'root' when elevated, else ''. The Windows principal API
    //   throws on pwsh for Linux/macOS (`$IsWindows` is $false there, and $null
    //   on Windows PowerShell 5), so those check for the root user instead.
    // Pure-PowerShell (no Dart interpolation), so a raw string is safe here.
    const cache =
        r'''if($null -eq $__omnyGit){$global:__omnyGit=[bool](Get-Command git -ErrorAction Ignore)};'''
        r'''if($null -eq $__omnyPv){$global:__omnyPv=if($IsWindows -eq $false){if([Environment]::UserName -eq 'root'){'root'}else{''}}elseif(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){'root'}else{''}};''';
    // One git process yields both branch and status: see the `## ` header of
    // `git status --porcelain -b` in [CwdMarker.command]. Where it fails (no
    // work tree: inside `.git/`, a bare repo), `rev-parse` names the branch as
    // a `## ` header, as the POSIX marker does.
    const compute =
        r'''$o=[Console]::Out;$br='';$st=@();if($__omnyGit){$st=@(git status --porcelain -b 2>$null);if($LASTEXITCODE -ne 0){$st=@('## '+("$(git rev-parse --abbrev-ref HEAD 2>$null)").Trim())}};$s=0;$m=0;$u=0;foreach($l in $st){if($l.StartsWith('## ')){$br=$l.Substring(3) -replace '^(No commits yet|Initial commit) on ','' -replace '\.\.\..*','' -replace ' .*','';continue};if($l -match '^\?\?'){$u++}else{if($l.Length -ge 1 -and $l[0] -ne ' '){$s++};if($l.Length -ge 2 -and $l[1] -ne ' '){$m++}}};$stat=if($s+$m+$u -gt 0){"+$s ~$m ?$u"}else{$null};$pv=$__omnyPv;''';
    // Emit one line: token (split halves) + cwd, then tab-separated fields and a
    // trailing newline. Tabs are [char]9, the newline [char]10.
    final write =
        "\$o.Write('$a'+'$b'+\$PWD.Path"
        r'+[char]9+$br+[char]9+$stat+[char]9+$pv'
        '${exitCode ? r'+[char]9+$__omnyEc' : ''}'
        r'+[char]10);$o.Flush()';
    return exitCode
        ? '$saveOk$saveLc$ec$cache$compute$write$restoreLc'
        : '$saveLc$cache$compute$write$restoreLc';
  }

  @override
  String pingMarker(CwdMarker marker) {
    final (a, b) = marker.tokenHalves;
    return "[Console]::Out.Write('$a'+'$b'+[char]10);[Console]::Out.Flush()";
  }

  @override
  String wrapCommand(
    String line, {
    required bool interactive,
    required String tail,
  }) {
    // PowerShell statement separator. No tty echo to toggle over a pipe;
    // PowerShell's own echo of this line is filtered by the client.
    return '$line ; $tail';
  }

  @override
  String completionCommand(String word, {required bool isCommand}) {
    final w = _psSingleQuote(word);
    final treatAsPath = !isCommand || word.contains('/') || word.contains(r'\');
    // `$w` holds the typed word. Split off any directory prefix on the last
    // separator (`/` or `\`) so each candidate keeps the prefix the user typed;
    // list the parent dir, filter by the leaf prefix, suffix `/` for containers.
    const pathBody =
        r"$i=[Math]::Max($w.LastIndexOf('/'),$w.LastIndexOf('\'));"
        r"if($i -ge 0){$pre=$w.Substring(0,$i+1);$leaf=$w.Substring($i+1)}"
        r"else{$pre='';$leaf=$w};$base=if($pre){$pre}else{'.'};"
        r"Get-ChildItem -Force -LiteralPath $base -ErrorAction SilentlyContinue|"
        r"Where-Object{$_.Name -like ($leaf+'*')}|"
        r'ForEach-Object{$p=$pre+$_.Name;if($_.PSIsContainer){"$p/"}else{"$p"}}';
    // Command position: every command whose name starts with the word —
    // applications on $PATH plus cmdlets/functions/aliases — by name, deduped.
    const cmdBody =
        r"Get-Command -All -CommandType Application,Cmdlet,Function,Alias "
        r"-Name ($w+'*') -ErrorAction SilentlyContinue|"
        r'ForEach-Object{$_.Name}|Sort-Object -Unique';
    return '\$w=$w;${treatAsPath ? pathBody : cmdBody}';
  }

  @override
  String listCommand(String args) {
    // `-Force` includes hidden and system items. `Length` is raw bytes, so the
    // table swaps it for a right-aligned 1024-based size (`512`, `4.2K`,
    // `1.3G`); directories show no size, as their `Length` is meaningless.
    const table =
        r"Format-Table Mode,LastWriteTime,@{N='Size';A='Right';E={"
        r"if($_.PSIsContainer){''}else{$n=[double]$_.Length;$i=0;"
        r"while($n -ge 1024 -and $i -lt 4){$n/=1024;$i++};"
        r"if($i -eq 0){'{0}' -f $n}else{'{0:0.#}{1}' -f $n,'BKMGT'[$i]}}}},"
        r'Name -AutoSize';
    final target = args.isEmpty ? '' : ' $args';
    return 'Get-ChildItem -Force$target | $table';
  }
}

/// Quotes [s] as a single-quoted PowerShell literal (embedded `'` doubled).
String _psSingleQuote(String s) => "'${s.replaceAll("'", "''")}'";

/// Windows `cmd.exe` — the degraded last resort. `cmd /Q` disables command echo;
/// [initLine] shrinks the prompt to `>`. The marker reports only the working
/// directory (`%CD%`): git branch/status and privilege are omitted, since `cmd`
/// cannot compute them inline. The token is written in two `set /p` pieces so it
/// never appears verbatim in the command text.
class CmdShellDialect extends ShellDialect {
  const CmdShellDialect();

  // Shrink the prompt that cmd prints before each piped command to a single `>`.
  @override
  String? get initLine => r'prompt $G';

  @override
  String fullMarker(CwdMarker marker) {
    final (a, b) = marker.tokenHalves;
    // `<nul set /p "=text"` prints text without a trailing newline; chain the
    // halves and the cwd, then a final `echo.` for the line terminator.
    return '<nul set /p "=$a"& <nul set /p "=$b%CD%"& echo.';
  }

  @override
  String pingMarker(CwdMarker marker) {
    final (a, b) = marker.tokenHalves;
    return '<nul set /p "=$a"& <nul set /p "=$b"& echo.';
  }

  @override
  String wrapCommand(
    String line, {
    required bool interactive,
    required String tail,
  }) {
    // `&` runs the marker regardless of the command's exit status.
    return '$line & $tail';
  }

  @override
  String completionCommand(String word, {required bool isCommand}) {
    // cmd has no robust quoting for the mixed `for`-set / `where` contexts
    // below, so drop the few characters that would break the command line.
    // Best-effort, matching this dialect's degraded marker (no rich git/priv);
    // words with spaces or cmd metacharacters may not complete under cmd.
    final w = word.replaceAll(RegExp(r'[\"%&|<>^]'), '');
    final treatAsPath = !isCommand || word.contains('/') || word.contains(r'\');
    if (treatAsPath) {
      // Directories first (suffixed `/`), then files (skipped by the dir test).
      // `for` keeps the directory prefix from the typed pattern.
      return 'for /d %A in ($w*) do @echo %A/'
          ' & for %A in ($w*) do @if not exist "%A\\" @echo %A';
    }
    // Command position: matching executables on %PATH% (and cwd), basenames
    // only (`%~nxA`); `where` honours %PATHEXT%.
    return 'for /f "delims=" %A in (\'where "$w*" 2^>nul\') do @echo %~nxA';
  }

  // `/a` includes hidden and system entries. cmd has no human-readable size
  // format, so sizes stay in bytes (with digit grouping) — the degraded case.
  @override
  String listCommand(String args) => args.isEmpty ? 'dir /a' : 'dir /a $args';
}
