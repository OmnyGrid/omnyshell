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
/// Whether the node's paths follow Windows rules comes from [remoteCwd]'s
/// form when known (`C:\…` vs `/…`, so Git Bash on Windows stays POSIX), else
/// from [arg]'s (the shell family cannot say: PowerShell runs on Linux and
/// macOS too). Windows paths come back in their native form
/// ([normalizeRemotePath]); on Git Bash, whose cwd is `/c/…`, a Windows path
/// argument (`C:\proj`) is taken in its `/c/proj` form ([msysPath]).
/// Returns `null` when the cwd is needed (a relative, drive-relative or
/// omitted path) but not yet known — the caller should ask the user to run a
/// command first or pass an absolute path.
String? resolveRemoteIdeRoot(String? arg, String? remoteCwd) {
  final windows = isWindowsRemotePath(remoteCwd ?? arg ?? '');
  final ctx = windows ? p.windows : p.posix;
  final cwd = remoteCwd == null
      ? null
      : normalizeRemotePath(remoteCwd, windows: windows);
  if (arg == null || arg.isEmpty || arg == '.') return cwd;
  if (!windows) {
    final msys = cwd != null && _msysRoot.hasMatch(cwd) ? msysPath(arg) : null;
    final path = msys ?? arg;
    if (ctx.isAbsolute(path)) return p.posix.normalize(path);
    if (cwd == null) return null;
    return p.posix.normalize(ctx.join(cwd, path));
  }
  // A bare drive (`C:`) means its root here, not that drive's current directory.
  final path = RegExp(r'^[A-Za-z]:$').hasMatch(arg) ? '$arg\\' : arg;
  if (RegExp(r'^[\\/](?![\\/])').hasMatch(path)) {
    // Rooted on the current drive (`\proj`): that is the cwd's drive.
    if (cwd == null) return null;
    return normalizeRemotePath(
      ctx.join(ctx.rootPrefix(cwd), path.substring(1)),
      windows: true,
    );
  }
  final driveRelative = _driveRelative.firstMatch(path);
  if (driveRelative != null) {
    // `D:x` is relative to drive D's own current directory: known only when
    // that is the cwd's drive.
    if (cwd == null ||
        cwd[0].toLowerCase() != driveRelative.group(1)!.toLowerCase()) {
      return null;
    }
    return normalizeRemotePath(
      ctx.join(cwd, driveRelative.group(2)!),
      windows: true,
    );
  }
  if (ctx.isAbsolute(path)) return normalizeRemotePath(path, windows: true);
  if (cwd == null) return null;
  return normalizeRemotePath(ctx.join(cwd, path), windows: true);
}

/// A Windows drive-relative path (`C:x`): a drive, then no separator.
final _driveRelative = RegExp(r'^([A-Za-z]):([^\\/].*)$');

/// A Git Bash (MSYS) absolute path: `/c`, `/c/…`.
final _msysRoot = RegExp(r'^/[A-Za-z](/|$)');

/// Windows path [path] (`C:\proj`, `C:/proj`) in the form Git Bash and other
/// MSYS tools use (`/c/proj`), or `null` when it is not a drive path.
String? msysPath(String path) {
  final m = RegExp(r'^([A-Za-z]):([\\/].*)?$').firstMatch(path);
  if (m == null) return null;
  final rest = (m.group(2) ?? '').replaceAll(r'\', '/');
  return p.posix.normalize('/${m.group(1)!.toLowerCase()}$rest');
}

/// The path rules for an IDE rooted at [rootPath] — Windows rules for a
/// Windows path (drive letters, shares, `\`, case-insensitive), POSIX rules
/// otherwise — whatever the platform the client itself runs on.
p.Context idePathContext(String rootPath) =>
    isWindowsRemotePath(rootPath) ? p.windows : p.posix;

/// [path] normalized under the path rules of a node: POSIX, or — when
/// [windows] (by default: when [path] is a Windows path) — Windows, in its
/// native form: `\` separators (`/` accepted on input, so `//server/share`
/// from git is the share it names), a drive root keeping its `\`, and `..`
/// stopping at the drive or share root.
String normalizeRemotePath(String path, {bool? windows}) {
  if (!(windows ?? isWindowsRemotePath(path))) return p.posix.normalize(path);
  final s = path.replaceAll('/', r'\');
  return p.windows.normalize(RegExp(r'^[A-Za-z]:$').hasMatch(s) ? '$s\\' : s);
}

/// [path] — absolute, or relative to [base] — resolved under [rootPath]'s path
/// rules ([idePathContext]), or `null` when it falls outside [rootPath] (the
/// IDE's sandbox for the agent's and the tree's paths). A Windows
/// drive-relative path (`C:x`, relative to a drive's own current directory,
/// which the IDE cannot know) is refused too.
String? resolveInWorkspace(String rootPath, String base, String path) {
  final paths = idePathContext(rootPath);
  if (paths.style == p.Style.windows && _driveRelative.hasMatch(path)) {
    return null;
  }
  final root = normalizeIdePath(paths, rootPath);
  final abs = normalizeIdePath(
    paths,
    paths.isAbsolute(path) ? path : paths.join(base, path),
  );
  return paths.equals(abs, root) || paths.isWithin(root, abs) ? abs : null;
}

/// [path] normalized under the rules of path context [ctx] (see
/// [normalizeRemotePath]); for code that holds an [idePathContext].
String normalizeIdePath(p.Context ctx, String path) =>
    normalizeRemotePath(path, windows: ctx.style == p.Style.windows);

/// Whether [path] is a Windows absolute path: `C:\…`, `C:/…`, a bare `C:`,
/// or a share (`\\server\share`). A `//`-prefixed path is not taken as one:
/// on a POSIX node that is an ordinary absolute path.
bool isWindowsRemotePath(String path) =>
    RegExp(r'^[A-Za-z]:([\\/]|$)').hasMatch(path) || path.startsWith(r'\\');

/// [s] single-quoted for a POSIX shell (`it's` → `'it'\''s'`).
String posixQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// [s] quoted as one argument for a shell of [syntax]: single quotes for a
/// POSIX shell or PowerShell (each with its own escape), double quotes for
/// `cmd` (which takes single quotes literally; Windows names hold no `"`).
String quoteForSyntax(String s, CommandSyntax syntax) => switch (syntax) {
  CommandSyntax.powershell => "'${s.replaceAll("'", "''")}'",
  CommandSyntax.windowsCmd => '"${s.replaceAll('"', '')}"',
  _ => posixQuote(s),
};

/// Maps a shell [family] to the `command_shield` [CommandSyntax] the IDE's AI
/// agent uses to validate the commands it runs. Defaults to bash.
CommandSyntax ideCommandSyntaxFor(ShellFamily? family) => switch (family) {
  ShellFamily.powershell => CommandSyntax.powershell,
  ShellFamily.cmd => CommandSyntax.windowsCmd,
  _ => CommandSyntax.bash,
};
