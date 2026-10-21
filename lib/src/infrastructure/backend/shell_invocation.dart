import 'dart:io';

import '../../domain/backend/shell_family.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/entities/session.dart';
import '../../shared/utils/omnyshell_home.dart';
import 'live_environment.dart';

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
///
/// [environment] is the one the session will get (default:
/// `liveProcessEnvironment`);
/// on Windows the shells are looked up on its `PATH`, which may be newer than
/// this process's (see `liveProcessEnvironment`).
(String, List<String>) resolveShellInvocation(
  ShellRequest request,
  String defaultShell, {
  Map<String, String>? environment,
}) {
  if (request.mode == SessionMode.shell) {
    final shell =
        request.command ??
        interactiveShell(defaultShell, environment: environment);
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
  // An explicit family hint (used by TAB-completion) runs the command under that
  // family's interpreter instead of the OS default exec shell — needed on
  // Windows, where [defaultShell] is always `cmd.exe` regardless of the family
  // the interactive session launched.
  final family = request.shellFamily;
  if (family != null) {
    return execInvocationForFamily(family, command, environment: environment);
  }
  return (defaultShell, [shellCommandFlag, command]);
}

/// Resolves the interpreter and args that run [command] as a one-shot under the
/// given [family], mirroring [interactiveShell]'s per-family resolution so an
/// exec (e.g. TAB-completion) matches the interactive session's shell:
///
/// - **posix**: `<bash>`/`/bin/sh -c "<command>"` (the Windows bash probe so it
///   matches a Git Bash/WSL interactive session, else `/bin/sh`).
/// - **powershell**: `<powershell> -NoLogo -NoProfile -Command "<command>"`.
/// - **cmd**: `<COMSPEC>/cmd.exe /c "<command>"`.
///
/// Windows shells are looked up in [environment] (default:
/// `liveProcessEnvironment`).
(String, List<String>) execInvocationForFamily(
  ShellFamily family,
  String command, {
  Map<String, String>? environment,
}) {
  final env = environment ?? liveProcessEnvironment();
  switch (family) {
    case ShellFamily.posix:
      final sh = Platform.isWindows
          ? (_resolveWindowsBash(env) ?? 'bash')
          : '/bin/sh';
      return (sh, ['-c', command]);
    case ShellFamily.powershell:
      final ps = Platform.isWindows
          ? (_resolveWindowsPowerShell(env) ?? 'powershell')
          : 'pwsh';
      return (ps, ['-NoLogo', '-NoProfile', '-Command', command]);
    case ShellFamily.cmd:
      return (env['COMSPEC'] ?? 'cmd.exe', ['/c', command]);
  }
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
///
/// On Windows the shells are looked up on [environment]'s `PATH` (default:
/// `liveProcessEnvironment`).
String interactiveShell(
  String defaultShell, {
  Map<String, String>? environment,
}) {
  if (Platform.isWindows) {
    return _resolveWindowsShell(environment ?? liveProcessEnvironment());
  }
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

/// Converts an MSYS/Cygwin-style absolute POSIX path (`/c/Users/x`, `/c`) — the
/// form Git Bash reports in `$PWD` — into a Windows path (`C:\Users\x`, `C:\`).
///
/// The interactive shell tracks its own cwd internally, but a client-supplied
/// cwd (e.g. the cached prompt cwd reused by TAB-completion's one-shot `exec`)
/// arrives in this MSYS form and would otherwise be handed verbatim to
/// `Process.start`/`winpty_spawn` as a working directory — which Windows cannot
/// `chdir` into, failing the spawn. [path] is returned unchanged when it is not
/// a `/<drive>/…` MSYS path (already a Windows path, relative, or a non-drive
/// POSIX path such as WSL's `/mnt/c/…` or `/home/…`, which we cannot map).
String windowsPathFromMsys(String path) {
  final match = RegExp(r'^/([A-Za-z])(/.*)?$').firstMatch(path);
  if (match == null) return path;
  final drive = match.group(1)!.toUpperCase();
  final rest = match.group(2) ?? '';
  return '$drive:\\${rest.replaceAll('/', r'\').replaceFirst(RegExp(r'^\\'), '')}';
}

/// The directory a session starts in, in order of who gets to decide.
///
/// 1. [requested] — what the client asked for, which always wins. A leading `~`
///    is expanded; a directory that does not exist fails the spawn, loudly,
///    which is the right answer to an explicit request that cannot be honoured.
/// 2. [configured] — what the node was built with, for an embedder with an
///    opinion about where its sessions belong.
/// 3. The user's home. A shell that opens wherever the node process happens to
///    be standing — `/usr/local/bin`, for an agent installed as a service — is
///    nobody's idea of a starting point, and `ssh` set the expectation long
///    ago. Skipped when that directory does not exist: handing a missing path
///    to `Process.start` would fail the session outright.
/// 4. `null` — inherit the node's own working directory, as before.
///
/// On Windows an MSYS path (`/c/Users/x`, the form Git Bash reports in `$PWD`)
/// is translated into one `chdir` accepts; see [windowsPathFromMsys].
String? resolveStartDirectory({
  String? requested,
  String? configured,
  Map<String, String>? environment,
}) {
  final explicit = requested ?? configured;
  final chosen = (explicit != null && explicit.trim().isNotEmpty)
      ? expandUserHome(explicit)
      : existingUserHome(environment: environment);
  if (chosen == null) return null;

  return Platform.isWindows && chosen.startsWith('/')
      ? windowsPathFromMsys(chosen)
      : chosen;
}

/// The first *usable* Windows bash (Git Bash / WSL), or `null` when none works.
/// Public shim over [_resolveWindowsBash] so the winpty backend can reuse the
/// same validated bash the interactive session launches. Looks on
/// [environment]'s `PATH` (default: `liveProcessEnvironment`).
String? resolveWindowsBash({Map<String, String>? environment}) =>
    _resolveWindowsBash(environment ?? liveProcessEnvironment());

/// Probes the Windows host for the best interactive shell, preferring a POSIX
/// bash, then PowerShell, then `cmd.exe`. See [_PathKeyedCache].
String _resolveWindowsShell(Map<String, String> env) =>
    _windowsShellCache.get(env, () => _probeWindowsShell(env))!;

final _windowsShellCache = _PathKeyedCache();

String _probeWindowsShell(Map<String, String> env) {
  return _resolveWindowsBash(env) ??
      _resolveWindowsPowerShell(env) ??
      env['COMSPEC'] ??
      'cmd.exe';
}

/// Probe results by `PATH`. Probing runs candidate shells (see
/// [_isUsableBash]), so it is not repeated per session; but `PATH` is the live
/// one (see `liveProcessEnvironment`), and a shell installed or removed while
/// the node runs changes it, so a new `PATH` is probed again.
///
/// A few `PATH`s are kept, most recently used last, because callers can
/// legitimately differ (with and without a node profile's `PATH`); a single
/// slot would re-probe each time they alternated.
class _PathKeyedCache {
  static const _slots = 4;
  final _byPath = <String, String?>{};

  String? get(Map<String, String> env, String? Function() probe) {
    final path = env['PATH'] ?? '';
    final String? value;
    if (_byPath.containsKey(path)) {
      value = _byPath.remove(path);
    } else {
      value = probe();
      if (_byPath.length >= _slots) _byPath.remove(_byPath.keys.first);
    }
    _byPath[path] = value; // (re)inserted as the most recently used
    return value;
  }
}

/// The first *usable* Windows bash (Git Bash / WSL), or `null` when none works.
///
/// `C:\Windows\System32\bash.exe` is the WSL launcher, which exists even when no
/// distro is installed but then errors out and exits 1 — so every candidate is
/// verified by actually running it before it's chosen. (System32 is on %PATH%,
/// so the WSL stub is still considered, just validated.) Cached until `PATH`
/// changes ([_PathKeyedCache]).
String? _resolveWindowsBash(Map<String, String> env) =>
    _windowsBashCache.get(env, () => _probeWindowsBash(env));

final _windowsBashCache = _PathKeyedCache();

String? _probeWindowsBash(Map<String, String> env) {
  for (final bash in _existingCandidates(env, 'bash.exe', const [
    r'%PROGRAMFILES%\Git\bin\bash.exe',
    r'%PROGRAMFILES%\Git\usr\bin\bash.exe',
    r'%PROGRAMFILES(X86)%\Git\bin\bash.exe',
    r'%LOCALAPPDATA%\Programs\Git\bin\bash.exe',
  ])) {
    if (_isUsableBash(bash)) return bash;
  }
  return null;
}

/// The best Windows PowerShell (`pwsh` preferred over `powershell`), or `null`.
String? _resolveWindowsPowerShell(Map<String, String> env) {
  return _firstExisting(env, 'pwsh.exe', const []) ??
      _firstExisting(env, 'powershell.exe', const [
        r'%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe',
      ]);
}

/// Whether [bashPath] is a working POSIX bash (rather than, e.g., the WSL stub
/// with no distro installed). Runs `bash -c "exit 0"` once and checks the exit
/// code; `runSync` captures the child's output so any error stays hidden, and
/// `exit 0` returns immediately so there is no risk of hanging.
bool _isUsableBash(String bashPath) {
  try {
    return Process.runSync(bashPath, ['-c', 'exit 0']).exitCode == 0;
  } on Object {
    return false;
  }
}

/// The first existing path for [exeName] on `%PATH%` or in the expanded
/// [fallbacks], or `null` when none are present.
String? _firstExisting(
  Map<String, String> env,
  String exeName,
  List<String> fallbacks,
) {
  final all = _existingCandidates(env, exeName, fallbacks);
  return all.isEmpty ? null : all.first;
}

/// All existing paths for [exeName], in priority order (each `%PATH%` directory
/// of [env] first, then the [fallbacks] expanded against [env]), de-duplicated.
List<String> _existingCandidates(
  Map<String, String> env,
  String exeName,
  List<String> fallbacks,
) {
  final found = <String>{};
  final pathDirs = (env['PATH'] ?? '').split(';');
  for (final dir in pathDirs) {
    if (dir.trim().isEmpty) continue;
    final candidate = '${dir.replaceAll(RegExp(r'[\\/]+$'), '')}\\$exeName';
    if (File(candidate).existsSync()) found.add(candidate);
  }
  for (final raw in fallbacks) {
    final expanded = _expandWindowsEnv(raw, env);
    if (expanded != null && File(expanded).existsSync()) found.add(expanded);
  }
  return found.toList();
}

/// Expands `%VAR%` references in a Windows path against [env], returning
/// `null` if any referenced variable is unset (so the candidate is skipped).
String? _expandWindowsEnv(String path, Map<String, String> env) {
  var missing = false;
  final result = path.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
    final value = env[m.group(1)!];
    if (value == null) missing = true;
    return value ?? '';
  });
  return missing ? null : result;
}
