import 'dart:io';

/// The current user's home directory, or `null` when there is no answer.
///
/// `HOME` (or `USERPROFILE`) is the answer whenever the process has one. A
/// process started by a service manager often does not: systemd hands a system
/// unit a minimal environment — `PATH`, `LANG`, even `USER` — but sets `HOME`
/// only if the unit asks for it. A node installed as a service therefore runs
/// without one, and so does every session it opens.
///
/// Where the environment is silent this asks the password database, which is
/// where a user's home directory actually lives. `/etc/passwd` is read directly
/// rather than shelled out to, because this sits on the path of every session
/// the node serves.
String? resolveUserHome({
  Map<String, String>? environment,
  String passwdPath = '/etc/passwd',
  String procStatusPath = '/proc/self/status',
}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home != null && home.isNotEmpty) return home;
  if (Platform.isWindows) return null;

  // A name, when the environment offers one. systemd sets `USER` for a system
  // unit even though it withholds `HOME`, so this is the common case.
  final user = env['USER'] ?? env['LOGNAME'];
  if (user != null && user.isNotEmpty) {
    final byName = _passwdField(passwdPath, (f) => f.first == user);
    if (byName != null) return byName;
  }

  // Otherwise the uid, which is the real key and is always available: a bare
  // container hands its process neither HOME nor USER.
  final uid = _selfUid(procStatusPath);
  if (uid != null) {
    final byUid = _passwdField(passwdPath, (f) => f[2] == '$uid');
    if (byUid != null) return byUid;
    // Every Unix agrees about root's, and a trimmed image is exactly where the
    // password database is most likely to be missing.
    if (uid == 0) return '/root';
  }
  return user == 'root' ? '/root' : null;
}

/// The home field of the first password entry [matches] accepts.
String? _passwdField(String passwdPath, bool Function(List<String>) matches) {
  try {
    final file = File(passwdPath);
    if (!file.existsSync()) return null;
    for (final line in file.readAsLinesSync()) {
      // name:password:uid:gid:gecos:home:shell
      final fields = line.split(':');
      if (fields.length > 5 && matches(fields)) {
        return fields[5].isEmpty ? null : fields[5];
      }
    }
  } on Object {
    // An unreadable password database is not a reason to fail a session.
  }
  return null;
}

/// This process's real uid, from `/proc`. Linux only; `null` anywhere else.
int? _selfUid(String procStatusPath) {
  try {
    final file = File(procStatusPath);
    if (!file.existsSync()) return null;
    for (final line in file.readAsLinesSync()) {
      // `Uid:\t<real>\t<effective>\t<saved>\t<fs>`
      if (!line.startsWith('Uid:')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length > 1) return int.tryParse(parts[1]);
    }
  } on Object {
    // Not Linux, or /proc is not mounted.
  }
  return null;
}

/// The user's home directory, but only when it exists on disk.
///
/// The distinction matters wherever the answer is about to be used as a
/// working directory: `Process.start` fails outright on one that is not there,
/// so a home that has been resolved but never created is worse than no answer.
String? existingUserHome({
  Map<String, String>? environment,
  String passwdPath = '/etc/passwd',
  String procStatusPath = '/proc/self/status',
}) {
  final home = resolveUserHome(
    environment: environment,
    passwdPath: passwdPath,
    procStatusPath: procStatusPath,
  );
  if (home == null || home.trim().isEmpty) return null;
  return Directory(home).existsSync() ? home : null;
}

/// Returns [environment] with `HOME` filled in, when nothing else supplies one.
///
/// A shell without `HOME` is subtly broken rather than obviously so: `cd ~`
/// goes nowhere and says nothing, `~/…` stops expanding, and anything keeping
/// state under a home directory — git, ssh, package managers — writes somewhere
/// else or gives up. A child inherits this process's `HOME` when there is one,
/// so this only speaks up when there is not.
Map<String, String> withUserHome(
  Map<String, String> environment, {
  Map<String, String>? processEnvironment,
  String passwdPath = '/etc/passwd',
  String procStatusPath = '/proc/self/status',
}) {
  if (environment.containsKey('HOME')) return environment;
  final parent = processEnvironment ?? Platform.environment;
  final inherited = parent['HOME'];
  if (inherited != null && inherited.isNotEmpty) return environment;

  final home = resolveUserHome(
    environment: parent,
    passwdPath: passwdPath,
    procStatusPath: procStatusPath,
  );
  if (home == null) return environment;
  return {...environment, 'HOME': home};
}

/// Resolves the OmnyShell home directory used for all local state
/// (`credentials.json`, `history/`, `*.uid`, ...).
///
/// The base directory resolves from `OMNYSHELL_HOME`, then the user's home
/// ([resolveUserHome]), falling back to the current directory. The returned
/// path is the `.omnyshell` directory inside that base.
String omnyshellHome({String? home}) {
  final env = Platform.environment;
  final base = home ?? env['OMNYSHELL_HOME'] ?? resolveUserHome() ?? '.';
  return '$base${Platform.pathSeparator}.omnyshell';
}

/// Joins [parts] onto the [omnyshellHome] directory with the platform
/// separator, e.g. `omnyshellPath(['history', 'a.history'])`.
String omnyshellPath(List<String> parts, {String? home}) {
  final sep = Platform.pathSeparator;
  return [omnyshellHome(home: home), ...parts].join(sep);
}

/// Expands a leading `~` (as `~`, `~/...` or `~\...`) in [path] to the current
/// user's home directory ([resolveUserHome]). Any other path — already
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
  final home = resolveUserHome();
  if (home == null || home.isEmpty) return path;
  if (path == '~') return home;
  return '$home${Platform.pathSeparator}${path.substring(2)}';
}
