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
