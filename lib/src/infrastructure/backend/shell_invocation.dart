import 'dart:io';

import '../../domain/backend/shell_family.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/entities/session.dart';

/// Resolves how a [ShellRequest] maps to an executable and arguments, shared by
/// the pipe-based and PTY-based backends so both honour the same rules:
///
/// - **shell** mode launches an interactive shell. On Windows the `connect`
///   protocol is POSIX-shaped, so [interactiveShell] prefers bash → PowerShell →
///   `cmd.exe`; when the client supplies no [ShellRequest.args], family-default
///   launch args ([defaultShellArgs]) put the shell into a quiet, prompt-free
///   stdin-reading mode the marker protocol assumes.
/// - **exec** mode runs the program directly when [ShellRequest.args] are given,
///   otherwise via `<shell> -c "<command>"` (`/c` on Windows). This always uses
///   the OS [defaultShell] (`cmd.exe` on Windows), unchanged.
(String, List<String>) resolveShellInvocation(
  ShellRequest request,
  String defaultShell,
) {
  if (request.mode == SessionMode.shell) {
    final shell = request.command ?? interactiveShell(defaultShell);
    final args = request.args.isNotEmpty
        ? request.args
        : defaultShellArgs(classifyShellFamily(shell));
    return (shell, args);
  }

  // exec: run the program directly if args were supplied, else via the shell.
  final command = request.command ?? '';
  if (request.args.isNotEmpty) {
    return (command, request.args);
  }
  return (defaultShell, [shellCommandFlag, command]);
}

/// The flag a shell uses to run a single command string (`-c`, `/c` on Windows).
String get shellCommandFlag => Platform.isWindows ? '/c' : '-c';

/// Resolves the node's default (exec-mode) shell from the environment: `$SHELL`
/// on POSIX, `%COMSPEC%`/`cmd.exe` on Windows. Interactive `shell` mode instead
/// uses [interactiveShell], which prefers a POSIX shell on Windows.
String resolveDefaultShell() {
  if (Platform.isWindows) {
    return Platform.environment['COMSPEC'] ?? 'cmd.exe';
  }
  final shell = Platform.environment['SHELL'];
  if (shell != null && shell.trim().isNotEmpty) return shell;
  return '/bin/sh';
}

/// Resolves the shell launched for an interactive session.
///
/// On POSIX this is the OS [defaultShell] (`$SHELL`). On Windows the `connect`
/// protocol is POSIX-shaped, so a POSIX shell is strongly preferred: probe for
/// **bash** (Git Bash / WSL) first, then **PowerShell** (`pwsh`/`powershell`),
/// and only fall back to `cmd.exe` as a last resort. The client adapts its marker
/// dialect to whichever family is launched (see [classifyShellFamily]).
String interactiveShell(String defaultShell) {
  if (Platform.isWindows) return _resolveWindowsShell();
  return defaultShell;
}

/// The default launch args that put a freshly-spawned interactive shell of
/// [family] into a quiet, prompt-free, stdin-reading mode (used only when the
/// client supplies no explicit args):
///
/// - **posix**: none — non-interactive bash/sh reading a pipe is already silent.
/// - **powershell**: `-NoLogo -NoProfile` so no banner/profile noise precedes the
///   command stream (the client's dialect suppresses the per-line prompt).
/// - **cmd**: `/Q` to disable command echo.
List<String> defaultShellArgs(ShellFamily family) => switch (family) {
  ShellFamily.posix => const [],
  ShellFamily.powershell => const ['-NoLogo', '-NoProfile'],
  ShellFamily.cmd => const ['/Q'],
};

/// Classifies a resolved shell [executable] into its [ShellFamily] by basename,
/// so the node can tell the client which command dialect to speak. Anything that
/// is not recognizably PowerShell or `cmd.exe` is treated as POSIX (covers `sh`,
/// `bash`, `zsh`, Git Bash, WSL, …).
ShellFamily classifyShellFamily(String executable) {
  final name = executable
      .split(RegExp(r'[\\/]'))
      .last
      .toLowerCase()
      .replaceAll(RegExp(r'\.exe$'), '');
  if (name == 'powershell' || name == 'pwsh') return ShellFamily.powershell;
  if (name == 'cmd') return ShellFamily.cmd;
  return ShellFamily.posix;
}

/// Probes the Windows host for the best interactive shell, preferring a POSIX
/// bash, then PowerShell, then `cmd.exe`. The result is cached for the process.
String _resolveWindowsShell() {
  return _cachedWindowsShell ??= _probeWindowsShell();
}

String? _cachedWindowsShell;

String _probeWindowsShell() {
  final bash = _findOnPathOrAt('bash.exe', const [
    r'%PROGRAMFILES%\Git\bin\bash.exe',
    r'%PROGRAMFILES%\Git\usr\bin\bash.exe',
    r'%PROGRAMFILES(X86)%\Git\bin\bash.exe',
    r'%LOCALAPPDATA%\Programs\Git\bin\bash.exe',
    r'%SYSTEMROOT%\System32\bash.exe',
  ]);
  if (bash != null) return bash;

  final pwsh = _findOnPathOrAt('pwsh.exe', const []);
  if (pwsh != null) return pwsh;

  final powershell = _findOnPathOrAt('powershell.exe', const [
    r'%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe',
  ]);
  if (powershell != null) return powershell;

  return Platform.environment['COMSPEC'] ?? 'cmd.exe';
}

/// Returns the absolute path to [exeName] found on `%PATH%`, or the first of the
/// expanded [fallbacks] that exists on disk, or `null` when none are present.
String? _findOnPathOrAt(String exeName, List<String> fallbacks) {
  final pathDirs = (Platform.environment['PATH'] ?? '').split(';');
  for (final dir in pathDirs) {
    if (dir.trim().isEmpty) continue;
    final candidate = '${dir.replaceAll(RegExp(r'[\\/]+$'), '')}\\$exeName';
    if (File(candidate).existsSync()) return candidate;
  }
  for (final raw in fallbacks) {
    final expanded = _expandWindowsEnv(raw);
    if (expanded != null && File(expanded).existsSync()) return expanded;
  }
  return null;
}

/// Expands `%VAR%` references in a Windows path, returning `null` if any
/// referenced variable is unset (so the candidate is skipped).
String? _expandWindowsEnv(String path) {
  final env = Platform.environment;
  var missing = false;
  final result = path.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
    final value = env[m.group(1)!];
    if (value == null) missing = true;
    return value ?? '';
  });
  return missing ? null : result;
}
