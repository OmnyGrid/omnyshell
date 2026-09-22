import 'dart:io';

import 'omnyshell_home.dart';

/// The directory `dart pub global activate` installs its executables into, or
/// `null` when it is not on this machine.
///
/// The answer is the one the Dart SDK itself uses:
///
/// 1. `$PUB_CACHE/bin`, when the environment names a cache explicitly.
/// 2. `%LOCALAPPDATA%\Pub\Cache\bin` on Windows (with the pre-2.8
///    `%APPDATA%\Pub\Cache\bin` accepted as a fallback for an older cache).
/// 3. `$HOME/.pub-cache/bin` everywhere else — the home resolved by
///    [resolveUserHome], so a node running as a service (which is handed no
///    `HOME`) still finds it.
///
/// Only a directory that exists is returned: an activated CLI has necessarily
/// created it, so a missing one means there is nothing to put on `PATH`.
String? pubCacheBinDir({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final sep = Platform.pathSeparator;

  final candidates = <String>[];
  final pubCache = env['PUB_CACHE'];
  if (pubCache != null && pubCache.trim().isNotEmpty) {
    candidates.add('${_trimTrailingSeparators(pubCache)}${sep}bin');
  }
  if (Platform.isWindows) {
    for (final key in const ['LOCALAPPDATA', 'APPDATA']) {
      final base = env[key];
      if (base == null || base.trim().isEmpty) continue;
      candidates.add(
        [_trimTrailingSeparators(base), 'Pub', 'Cache', 'bin'].join(sep),
      );
    }
  } else {
    final home = resolveUserHome(environment: env);
    if (home != null && home.trim().isNotEmpty) {
      candidates.add('${_trimTrailingSeparators(home)}$sep.pub-cache${sep}bin');
    }
  }

  for (final candidate in candidates) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Returns [environment] with the pub cache `bin` directory ([pubCacheBinDir])
/// on `PATH`, appended when it is not already there.
///
/// OmnyShell is itself a Dart CLI installed by `dart pub global activate`, and
/// so is much of what an operator reaches for in a session. Those executables
/// live in the pub cache's `bin`, which is on `PATH` only because a shell rc
/// put it there — and sessions run rc-less (see `NodeProfile`), so `omnyshell`
/// would be missing from the very shell OmnyShell opened. The directory is
/// appended rather than prepended: an operator's own `PATH` ordering, whether
/// inherited or from the node profile, keeps precedence.
///
/// Both the cache and the `PATH` extended are the ones the child will actually
/// see: what [environment] says, falling back to what it inherits from
/// [processEnvironment] (the backends all spawn with
/// `includeParentEnvironment: true`), so a `PUB_CACHE` set in the node profile
/// names the cache the session will really use. On Windows the `PATH` variable
/// is matched case-insensitively, because the inherited environment spells it
/// `Path`.
Map<String, String> withPubCacheBin(
  Map<String, String> environment, {
  Map<String, String>? processEnvironment,
}) {
  final parent = processEnvironment ?? Platform.environment;
  final binDir = pubCacheBinDir(environment: {...parent, ...environment});
  if (binDir == null) return environment;

  final ownKey = _pathKey(environment);
  final inheritedKey = _pathKey(parent);
  final key = ownKey ?? inheritedKey ?? 'PATH';
  final current = ownKey != null
      ? environment[ownKey]!
      : (inheritedKey != null ? parent[inheritedKey]! : '');
  final separator = Platform.isWindows ? ';' : ':';

  final already = current
      .split(separator)
      .where((e) => e.trim().isNotEmpty)
      .any((e) => _samePath(e, binDir));
  if (already) return environment;

  return {
    ...environment,
    key: current.isEmpty ? binDir : '$current$separator$binDir',
  };
}

/// The key [environment] spells `PATH` with, or `null` when it carries none.
/// Windows environments are case-insensitive and usually say `Path`.
String? _pathKey(Map<String, String> environment) {
  if (environment.containsKey('PATH')) return 'PATH';
  if (!Platform.isWindows) return null;
  for (final key in environment.keys) {
    if (key.toUpperCase() == 'PATH') return key;
  }
  return null;
}

/// Whether two `PATH` entries name the same directory, ignoring a trailing
/// separator (and case on Windows).
bool _samePath(String a, String b) {
  final left = _trimTrailingSeparators(a.trim());
  final right = _trimTrailingSeparators(b.trim());
  return Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;
}

String _trimTrailingSeparators(String path) =>
    path.replaceFirst(RegExp(r'[\\/]+$'), '');
