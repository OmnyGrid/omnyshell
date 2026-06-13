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

  /// The full marker command: reports cwd plus git branch/status and privilege.
  String fullMarker(CwdMarker marker);

  /// The lightweight ping marker: signals completion only (no git queries).
  String pingMarker(CwdMarker marker);

  /// Wraps a user-typed [line] so it runs and is followed by [tail] (a marker)
  /// as one logical unit. [interactive] enables terminal-echo handling where the
  /// dialect needs it (POSIX only; pipe-based Windows shells don't echo stdin).
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
}

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
}

/// Quotes [s] as a single POSIX shell word so it is taken literally.
String _posixSingleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Windows PowerShell (`pwsh`/`powershell`). The shell reads commands from a
/// redirected stdin (so input is never echoed); [initLine] silences the
/// per-line prompt. The marker computes git status counts and the admin flag in
/// PowerShell and writes one line directly to the console out.
class PowerShellDialect extends ShellDialect {
  const PowerShellDialect();

  // Redefine the prompt function to emit nothing, so the REPL adds no prompt
  // text between commands; continue past non-terminating errors.
  @override
  String? get initLine =>
      r"function prompt { '' }; $ErrorActionPreference='Continue'";

  @override
  String fullMarker(CwdMarker marker) {
    final (a, b) = marker.tokenHalves;
    // Compute the fields in PowerShell: branch via git, status counts mirror the
    // POSIX awk (+staged ~modified ?untracked), privilege = 'root' when elevated.
    // Unset fields are $null so they render as empty (matching the POSIX marker).
    // Pure-PowerShell (no Dart interpolation), so a raw string is safe here.
    const compute =
        r'''$o=[Console]::Out;$br=("$(git rev-parse --abbrev-ref HEAD 2>$null)").Trim();$st=@(git status --porcelain 2>$null);$s=0;$m=0;$u=0;foreach($l in $st){if($l -match '^\?\?'){$u++}else{if($l.Length -ge 1 -and $l[0] -ne ' '){$s++};if($l.Length -ge 2 -and $l[1] -ne ' '){$m++}}};$stat=if($s+$m+$u -gt 0){"+$s ~$m ?$u"}else{$null};$pv=if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){'root'}else{$null};''';
    // Emit one line: token (split halves) + cwd, then tab-separated fields and a
    // trailing newline. Tabs are [char]9, the newline [char]10.
    final write =
        "\$o.Write('$a'+'$b'+\$PWD.Path"
        r'+[char]9+$br+[char]9+$stat+[char]9+$pv+[char]10);$o.Flush()';
    return '$compute$write';
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
    // PowerShell statement separator; no echo control needed over a pipe.
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
}
