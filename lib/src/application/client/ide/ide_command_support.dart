import 'package:command_shield/command_shield.dart' show CommandSyntax;
import 'package:path/path.dart' as p;

import '../../../domain/backend/shell_family.dart';

/// Helpers shared by the native `:ide` command and a web client's `:ide`, kept
/// `dart:io`-free so both (CLI and browser) resolve the IDE root and pick the
/// agent's command syntax identically.

/// Resolves the remote IDE root from an optional [arg] and the current remote
/// working directory [remoteCwd]:
///
/// * an absolute remote path — POSIX (`/srv/app`) or Windows (`C:\proj`,
///   `\\server\share`) — is normalized and used as-is;
/// * a relative path is joined onto [remoteCwd];
/// * no argument (or `.`) uses [remoteCwd] itself.
///
/// Windows paths come back with `/` separators ([normalizeRemotePath]).
/// Returns `null` when the cwd is needed (relative or omitted path) but not yet
/// known — the caller should ask the user to run a command first or pass an
/// absolute path.
String? resolveRemoteIdeRoot(String? arg, String? remoteCwd) {
  final windows =
      isWindowsRemotePath(arg ?? '') || isWindowsRemotePath(remoteCwd ?? '');
  String norm(String s) => windows ? s.replaceAll(r'\', '/') : s;
  final cwd = remoteCwd == null ? null : norm(remoteCwd);
  if (arg == null || arg.isEmpty || arg == '.') return cwd;
  final path = norm(arg);
  if (p.posix.isAbsolute(path) || isWindowsRemotePath(path)) {
    return _normalize(path, windows: windows);
  }
  if (cwd == null) return null;
  return _normalize(p.posix.join(cwd, path), windows: windows);
}

/// [path] normalized with POSIX rules, keeping what those rules would break in
/// a Windows path: a share's leading `//` (POSIX collapses it to `/`), and a
/// drive root's slash (`C:` alone means that drive's *current directory* to
/// Windows, not its root).
String _normalize(String path, {required bool windows}) {
  if (!windows) return p.posix.normalize(path);
  if (path.startsWith('//')) return '/${p.posix.normalize(path.substring(1))}';
  final n = p.posix.normalize(path);
  return RegExp(r'^[A-Za-z]:$').hasMatch(n) ? '$n/' : n;
}

/// [path] in the form the IDE uses for remote paths: a Windows path (a drive,
/// `C:\…`, or a share, `\\server\…`) with `/` separators — the form git
/// reports, which Windows accepts too — so roots, git paths and joined paths
/// compare equal. A POSIX path is returned as it is.
String normalizeRemotePath(String path) =>
    isWindowsRemotePath(path) ? path.replaceAll(r'\', '/') : path;

/// Whether [path] is a Windows absolute path: `C:\…`, `C:/…`, or a share.
bool isWindowsRemotePath(String path) =>
    RegExp(r'^[A-Za-z]:([\\/]|$)').hasMatch(path) ||
    path.startsWith(r'\\') ||
    path.startsWith('//');

/// Maps a shell [family] to the `command_shield` [CommandSyntax] the IDE's AI
/// agent uses to validate the commands it runs. Defaults to bash.
CommandSyntax ideCommandSyntaxFor(ShellFamily? family) => switch (family) {
  ShellFamily.powershell => CommandSyntax.powershell,
  ShellFamily.cmd => CommandSyntax.windowsCmd,
  _ => CommandSyntax.bash,
};
