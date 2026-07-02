import 'dart:convert';
import 'dart:io';

import 'package:omnydrive/omnydrive.dart'
    show GitCredential, GitCredentialResolver, GitCredentialStore, OriginUri;

import '../../shared/utils/omnyshell_home.dart';

/// The node-local git-credential file. Kept distinct from the client/hub auth
/// store (`credentials.json`) so the two never collide, even though both live in
/// `~/.omnyshell/`.
const String gitCredentialsFileName = 'git-credentials.json';

/// Node-host git credentials for reaching private remotes, split into a
/// **global** (node-wide) scope and optional **per-principal** scopes.
///
/// Git clone/push runs on the node, so credentials are node-local state. A drive
/// session carries the authenticated principal ([resolverFor]); credentials
/// resolve **principal-first, then global**: the connecting principal's
/// credential for a host wins, falling back to the node's global credential when
/// the principal has none. One principal never sees another's credential.
///
/// Persisted at `~/.omnyshell/git-credentials.json` (mode 600) as:
/// ```json
/// { "credentials": { "<host>": { .. } },                       // global
///   "principals": { "<principal>": { "credentials": { "<host>": { .. } } } } }
/// ```
/// The `principals` key is optional, so a legacy flat file (global only) loads
/// unchanged. Principals are JSON keys, so arbitrary identity strings (`@`, `/`,
/// unicode) are safe — no filename sanitization is involved. Each scope reuses
/// omnydrive's host-keyed [GitCredentialStore]; only the outer structure and
/// file I/O live here.
class NodeGitCredentials {
  final GitCredentialStore _global;
  final Map<String, GitCredentialStore> _byPrincipal;

  NodeGitCredentials._(this._global, this._byPrincipal);

  /// An empty set of credentials.
  factory NodeGitCredentials.empty() => NodeGitCredentials._(
    GitCredentialStore(),
    <String, GitCredentialStore>{},
  );

  /// The global (node-wide) credential scope.
  GitCredentialStore get global => _global;

  /// The principals that currently have at least one credential.
  List<String> get principals => [
    for (final e in _byPrincipal.entries)
      if (e.value.hosts.isNotEmpty) e.key,
  ]..sort();

  /// The credential store for [principal], or null if none exists.
  GitCredentialStore? storeFor(String principal) => _byPrincipal[principal];

  /// The scope the CLI mutates: the global store when [principal] is null, else
  /// [principal]'s store (created on demand so `put` can target it).
  GitCredentialStore scopeFor({String? principal}) => principal == null
      ? _global
      : _byPrincipal.putIfAbsent(principal, GitCredentialStore.new);

  /// A resolver for a connecting [principal]: principal-first, global fallback.
  GitCredentialResolver resolverFor(String principal) =>
      _PrincipalFirstResolver(_byPrincipal[principal], _global);

  static String path({String? home}) =>
      omnyshellPath([gitCredentialsFileName], home: home);

  /// Loads the credentials, returning an empty set when no file exists yet.
  static Future<NodeGitCredentials> load({String? home}) async {
    final file = File(path(home: home));
    if (!await file.exists()) return NodeGitCredentials.empty();
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    // The top level is itself a `{credentials: {...}}` map — the global scope.
    final global = GitCredentialStore.fromJson(json);
    final byPrincipal = <String, GitCredentialStore>{};
    final rawPrincipals = json['principals'];
    if (rawPrincipals is Map) {
      rawPrincipals.forEach((principal, value) {
        byPrincipal[principal.toString()] = GitCredentialStore.fromJson(
          value as Map<String, dynamic>,
        );
      });
    }
    return NodeGitCredentials._(global, byPrincipal);
  }

  /// Persists to `~/.omnyshell/git-credentials.json`, creating `~/.omnyshell`
  /// (mode 700) and tightening the file to mode 600 on POSIX. Empty principal
  /// scopes are pruned so removing the last credential leaves no stray entry.
  Future<void> save({String? home}) async {
    final file = File(path(home: home));
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _chmod(dir.path, '700');
    }
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    await _chmod(file.path, '600');
  }

  Map<String, dynamic> toJson() {
    final principals = {
      for (final e in _byPrincipal.entries)
        if (e.value.hosts.isNotEmpty) e.key: e.value.toJson(),
    };
    return {
      ..._global.toJson(), // -> "credentials": { ... }
      if (principals.isNotEmpty) 'principals': principals,
    };
  }

  static Future<void> _chmod(String path, String mode) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', [mode, path]);
  }
}

/// Resolves a host credential from a principal's scope first, then the global
/// scope. A null [_principal] scope (principal has no credentials at all) simply
/// falls through to global.
class _PrincipalFirstResolver implements GitCredentialResolver {
  final GitCredentialStore? _principal;
  final GitCredentialStore _global;

  _PrincipalFirstResolver(this._principal, this._global);

  @override
  GitCredential? resolve(OriginUri origin) =>
      _principal?.resolve(origin) ?? _global.resolve(origin);
}
