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
}

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
}

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
}
