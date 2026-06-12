import 'dart:io';

/// Resolves the OmnyShell home directory used for all local state
/// (`credentials.json`, `history/`, `*.uid`, ...).
///
/// The base directory resolves from `OMNYSHELL_HOME`, then `HOME`, then
/// `USERPROFILE`, falling back to the current directory. The returned path is
/// the `.omnyshell` directory inside that base.
String omnyshellHome({String? home}) {
  final env = Platform.environment;
  final base =
      home ?? env['OMNYSHELL_HOME'] ?? env['HOME'] ?? env['USERPROFILE'] ?? '.';
  return '$base${Platform.pathSeparator}.omnyshell';
}

/// Joins [parts] onto the [omnyshellHome] directory with the platform
/// separator, e.g. `omnyshellPath(['history', 'a.history'])`.
String omnyshellPath(List<String> parts, {String? home}) {
  final sep = Platform.pathSeparator;
  return [omnyshellHome(home: home), ...parts].join(sep);
}

/// Expands a leading `~` (as `~`, `~/...` or `~\...`) in [path] to the current
/// user's home directory (`HOME`, then `USERPROFILE`). Any other path — already
/// absolute, relative, or with `~` elsewhere — is returned unchanged.
///
/// Used on the node to resolve client-supplied paths (drive mount roots and
/// exec working directories) against the node user's home, so an ephemeral
/// default like `~/.omnyshell/run/...` lands somewhere writable regardless of
/// the node process's current directory.
String expandUserHome(String path) {
  if (path != '~' && !path.startsWith('~/') && !path.startsWith(r'~\')) {
    return path;
  }
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home == null || home.isEmpty) return path;
  if (path == '~') return home;
  return '$home${Platform.pathSeparator}${path.substring(2)}';
}
