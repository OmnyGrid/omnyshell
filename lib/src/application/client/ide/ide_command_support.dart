import 'package:command_shield/command_shield.dart' show CommandSyntax;
import 'package:path/path.dart' as p;

import '../../../domain/backend/shell_family.dart';

/// Helpers shared by the native `:ide` command and a web client's `:ide`, kept
/// `dart:io`-free so both (CLI and browser) resolve the IDE root and pick the
/// agent's command syntax identically.

/// Resolves the remote IDE root from an optional [arg] and the current remote
/// working directory [remoteCwd]:
///
/// * an absolute remote (POSIX) path is normalized and used as-is;
/// * a relative path is joined onto [remoteCwd];
/// * no argument (or `.`) uses [remoteCwd] itself.
///
/// Returns `null` when the cwd is needed (relative or omitted path) but not yet
/// known — the caller should ask the user to run a command first or pass an
/// absolute path.
String? resolveRemoteIdeRoot(String? arg, String? remoteCwd) {
  if (arg == null || arg.isEmpty || arg == '.') return remoteCwd;
  if (p.posix.isAbsolute(arg)) return p.posix.normalize(arg);
  if (remoteCwd == null) return null;
  return p.posix.normalize(p.posix.join(remoteCwd, arg));
}

/// Maps a shell [family] to the `command_shield` [CommandSyntax] the IDE's AI
/// agent uses to validate the commands it runs. Defaults to bash.
CommandSyntax ideCommandSyntaxFor(ShellFamily? family) => switch (family) {
  ShellFamily.powershell => CommandSyntax.powershell,
  ShellFamily.cmd => CommandSyntax.windowsCmd,
  _ => CommandSyntax.bash,
};
