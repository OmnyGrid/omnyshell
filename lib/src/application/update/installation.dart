/// How the running `omnyshell` was installed, so `omnyshell update` can update
/// it the same way.
///
/// Dart offers two ways to install a CLI, and both leave a `pubspec.lock` next
/// to the installed package that records where it came from:
///
/// - `dart pub global activate` keeps the package under the pub cache's
///   `global_packages/<package>/` and runs it from a snapshot there (or, for a
///   path activation, from the package's own checkout).
/// - `dart install` compiles it ahead of time into
///   `…/install/app-bundles/<package>/<source>/<version>/bundle/bin/`.
///
/// [detectInstallation] tells them apart from the running process, and
/// [Installation.updateCommand] rebuilds the command that installed it — same
/// tool, same source (pub.dev or another hosted repository, a git repository,
/// a local path).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The tool that installed the package.
enum InstallMethod {
  /// `dart pub global activate`.
  pubGlobal('dart pub global activate'),

  /// `dart install`.
  dartInstall('dart install');

  /// The command, as the user knows it.
  final String command;

  const InstallMethod(this.command);
}

/// Where an installed package came from, as its `pubspec.lock` records it.
sealed class PackageSource {
  const PackageSource();
}

/// A package repository (pub.dev, or a private one at [url]).
final class HostedSource extends PackageSource {
  /// The repository's base URL, e.g. `https://pub.dev`.
  final String url;

  const HostedSource(this.url);

  /// Whether this is the default repository (pub.dev), which needs no flag.
  bool get isDefault {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'pub.dev' || host == 'pub.dartlang.org';
  }

  @override
  String toString() => isDefault ? 'pub.dev' : url;
}

/// A git repository: [url], at [ref] (a branch, tag or commit), with the
/// package in [path] inside it.
final class GitSource extends PackageSource {
  final String url;
  final String? ref;
  final String path;

  const GitSource(this.url, {this.ref, this.path = '.'});

  @override
  String toString() =>
      'git $url${ref == null ? '' : ' @ $ref'}'
      '${path == '.' ? '' : ' ($path)'}';
}

/// A local checkout at [path].
final class PathSource extends PackageSource {
  final String path;

  const PathSource(this.path);

  @override
  String toString() => 'local path $path';
}

/// An installation of [package] found by [detectInstallation].
class Installation {
  final String package;
  final InstallMethod method;
  final PackageSource source;

  /// The installed version, from the lock file.
  final String version;

  /// The installation's directory: `global_packages/<package>` for
  /// [InstallMethod.pubGlobal], `app-bundles/<package>/<source>/<version>`
  /// for [InstallMethod.dartInstall]. Holds the `pubspec.lock`.
  final String root;

  const Installation({
    required this.package,
    required this.method,
    required this.source,
    required this.version,
    required this.root,
  });

  /// Whether a version can be asked for: only a hosted package has versions;
  /// git and path installs take whatever their source holds.
  bool get canTargetVersion => source is HostedSource;

  /// The command that updates this installation the way it was installed,
  /// run with [dart] (the `dart` executable). [version] pins a version (a
  /// hosted source only); without it the latest is installed.
  List<String> updateCommand({required String dart, String? version}) {
    if (version != null && !canTargetVersion) {
      throw ArgumentError(
        'a version can only be chosen for a hosted package ($source)',
      );
    }
    return switch (method) {
      InstallMethod.pubGlobal => [
        dart,
        'pub',
        'global',
        'activate',
        ..._activateArgs(version),
      ],
      InstallMethod.dartInstall => [
        dart,
        'install',
        _installDescriptor(version),
      ],
    };
  }

  List<String> _activateArgs(String? version) => switch (source) {
    HostedSource(:final url, :final isDefault) => [
      package,
      ?version,
      if (!isDefault) ...['--hosted-url', url],
    ],
    GitSource(:final url, :final ref, :final path) => [
      '--source',
      'git',
      url,
      if (ref != null) ...['--git-ref', ref],
      if (path != '.') ...['--git-path', path],
    ],
    PathSource(:final path) => ['--source', 'path', path],
  };

  /// `<package>[@<descriptor>]`, as `dart install` takes it.
  String _installDescriptor(String? version) => switch (source) {
    HostedSource(:final isDefault) when isDefault =>
      version == null ? package : '$package@${_yaml(version)}',
    HostedSource(:final url) =>
      '$package@{hosted: ${_yaml(url)}'
          '${version == null ? '' : ', version: ${_yaml(version)}'}}',
    GitSource(:final url, :final ref, :final path) =>
      '$package@{git: {url: ${_yaml(url)}'
          '${ref == null ? '' : ', ref: ${_yaml(ref)}'}'
          '${path == '.' ? '' : ', path: ${_yaml(path)}'}}}',
    PathSource(:final path) => '$package@{path: ${_yaml(path)}}',
  };

  /// The command that runs the `omnyshell` this installation holds *now* (so,
  /// after [updateCommand], the new one) directly — not through a wrapper on
  /// `PATH`, which `sudo` or an elevated Windows prompt would not find, or
  /// would resolve against another user's pub cache. [dart] is the `dart`
  /// executable. For `dart install`, [version] names the version installed
  /// (its folder is used when present; otherwise the most recently written
  /// one). `null` when it cannot be found.
  List<String>? directLauncher({required String dart, String? version}) {
    switch (method) {
      case InstallMethod.pubGlobal:
        if (source case PathSource(:final path)) {
          final script = p.join(path, 'bin', '$package.dart');
          return File(script).existsSync() ? [dart, script] : null;
        }
        final snapshot = _newest(
          Directory(p.join(root, 'bin')),
          (name) =>
              name.startsWith('$package.dart') && name.endsWith('.snapshot'),
        );
        return snapshot == null ? null : [dart, snapshot];
      case InstallMethod.dartInstall:
        // `<bundles>/<version>/bundle/bin/<exe>`: the newest version's binary,
        // since an update installs beside the old one.
        final exe = Platform.isWindows ? '$package.exe' : package;
        final versions = Directory(p.dirname(root));
        if (!versions.existsSync()) return null;
        if (version != null) {
          final wanted = File(
            p.join(versions.path, version, 'bundle', 'bin', exe),
          );
          if (wanted.existsSync()) return [wanted.path];
        }
        final candidates =
            [
              for (final dir in versions.listSync().whereType<Directory>())
                File(p.join(dir.path, 'bundle', 'bin', exe)),
            ].where((f) => f.existsSync()).toList()..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
            );
        return candidates.isEmpty ? null : [candidates.first.path];
    }
  }

  @override
  String toString() => '$package $version via ${method.command} ($source)';
}

/// The installation of [package] the running process belongs to, or `null`
/// when it was not installed by either tool (run from a checkout with
/// `dart run`, compiled by hand, …).
///
/// [script] and [resolvedExecutable] default to the running process's;
/// [pubCache] to the pub cache in use (`PUB_CACHE`, else the platform
/// default).
Installation? detectInstallation({
  String package = 'omnyshell',
  Uri? script,
  String? resolvedExecutable,
  String? pubCache,
}) {
  script ??= Platform.script;
  resolvedExecutable ??= Platform.resolvedExecutable;

  // `dart pub global activate` (hosted or git): running the snapshot in
  // `global_packages/<package>/bin/`.
  if (script.isScheme('file')) {
    final root = _rootAfter(script.toFilePath(), ['global_packages', package]);
    if (root != null) {
      return _fromLock(package, InstallMethod.pubGlobal, root);
    }
  }

  // `dart install`: the compiled binary, in
  // `app-bundles/<package>/<source>/<version>/bundle/bin/`.
  final exe = _resolveLinks(resolvedExecutable);
  final bundles = _rootAfter(exe, ['app-bundles', package]);
  if (bundles != null) {
    final rest = p.split(p.relative(exe, from: bundles));
    if (rest.length >= 2) {
      return _fromLock(
        package,
        InstallMethod.dartInstall,
        p.join(bundles, rest[0], rest[1]),
      );
    }
  }

  // `dart pub global activate --source path`: pub runs the checkout itself, so
  // only the activation record in the pub cache tells it apart from a plain
  // `dart run` in that checkout.
  if (script.isScheme('file')) {
    final root = p.join(
      pubCache ?? defaultPubCache(),
      'global_packages',
      package,
    );
    final found = _fromLock(package, InstallMethod.pubGlobal, root);
    // Resolved, since the activation and the run may name the checkout
    // through different links (macOS's /var → /private/var, a symlinked
    // workspace).
    if (found?.source case PathSource(:final path)
        when p.isWithin(
          _resolveLinks(path, directory: true),
          _resolveLinks(script.toFilePath()),
        )) {
      return found;
    }
  }
  return null;
}

/// Why updating [install] under `sudo` must be refused, or `null` when it is
/// fine: `sudo omnyshell update` on another user's installation would update
/// their pub cache (or app bundles) as root, leaving root-owned files there.
/// The update asks for administrator rights itself, only where needed. Root's
/// own installation (under `/root` or `/var/root`) may be updated as root.
String? sudoMisuse(
  Installation install, {
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  if ((operatingSystem ?? Platform.operatingSystem) == 'windows') return null;
  final sudoUser = (environment ?? Platform.environment)['SUDO_USER'];
  if (sudoUser == null || sudoUser.isEmpty || sudoUser == 'root') return null;
  // macOS resolves /var to /private/var, as `dart install` paths are.
  const rootHomes = ['/root/', '/var/root/', '/private/var/root/'];
  if (rootHomes.any(install.root.startsWith)) return null;
  return 'run `omnyshell update` without sudo: it updates $sudoUser\'s '
      'installation as $sudoUser, and asks for administrator rights itself, '
      'only to refresh system services.';
}

/// The pub cache directory: `PUB_CACHE`, else `%LOCALAPPDATA%\Pub\Cache` on
/// Windows and `~/.pub-cache` elsewhere.
String defaultPubCache({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final explicit = env['PUB_CACHE'];
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (Platform.isWindows) {
    return p.join(env['LOCALAPPDATA'] ?? '', 'Pub', 'Cache');
  }
  return p.join(env['HOME'] ?? '', '.pub-cache');
}

/// Reads [root]'s `pubspec.lock` entry for [package], or `null` when there is
/// none or it cannot be understood.
Installation? _fromLock(String package, InstallMethod method, String root) {
  final lock = File(p.join(root, 'pubspec.lock'));
  if (!lock.existsSync()) return null;
  try {
    final doc = loadYaml(lock.readAsStringSync());
    final entry = (doc is Map ? doc['packages'] : null) is Map
        ? (doc['packages'] as Map)[package]
        : null;
    if (entry is! Map) return null;
    final source = parseLockSource(entry);
    final version = entry['version'];
    if (source == null || version == null) return null;
    return Installation(
      package: package,
      method: method,
      source: source,
      version: '$version',
      root: root,
    );
  } on YamlException {
    return null;
  }
}

/// The [PackageSource] of a `pubspec.lock` package entry, or `null` for a
/// source this command does not know how to reinstall from.
PackageSource? parseLockSource(Map<dynamic, dynamic> entry) {
  final description = entry['description'];
  final d = description is Map ? description : const {};
  switch (entry['source']) {
    case 'hosted':
      return HostedSource('${d['url'] ?? 'https://pub.dev'}');
    case 'git':
      final url = d['url'];
      if (url == null) return null;
      return GitSource(
        '$url',
        ref: d['ref'] == null ? null : '${d['ref']}',
        path: '${d['path'] ?? '.'}',
      );
    case 'path':
      final path = d['path'];
      return path == null ? null : PathSource('$path');
    default:
      return null;
  }
}

/// The path of [path] up to and including the [segments] run (compared
/// case-insensitively on Windows), or `null` when it has no such run.
String? _rootAfter(String path, List<String> segments) {
  final parts = p.split(path);
  bool same(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  for (var i = 0; i + segments.length <= parts.length; i++) {
    var match = true;
    for (var j = 0; j < segments.length; j++) {
      if (!same(parts[i + j], segments[j])) {
        match = false;
        break;
      }
    }
    if (match) return p.joinAll(parts.take(i + segments.length));
  }
  return null;
}

/// [path] with its symbolic links resolved, made canonical; as given (but
/// canonical) when it does not exist.
String _resolveLinks(String path, {bool directory = false}) {
  try {
    return p.canonicalize(
      directory
          ? Directory(path).resolveSymbolicLinksSync()
          : File(path).resolveSymbolicLinksSync(),
    );
  } on FileSystemException {
    return p.canonicalize(path);
  }
}

/// The most recently modified file in [dir] whose name [matches], or `null`.
String? _newest(Directory dir, bool Function(String name) matches) {
  if (!dir.existsSync()) return null;
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => matches(p.basename(f.path)))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return files.isEmpty ? null : files.first.path;
}

/// [s] as a YAML flow scalar for a `dart install` descriptor: plain only when
/// it is a simple word or version (`1.64.0`, `main`); anything else — URLs,
/// paths, constraints like `>=1.0.0` (a leading `>` would start a block
/// scalar) — single-quoted, so YAML takes it literally.
String _yaml(String s) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.+-]*$').hasMatch(s)
    ? s
    : "'${s.replaceAll("'", "''")}'";
