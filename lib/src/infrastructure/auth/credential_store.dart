import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../../shared/errors/omnyshell_exception.dart';
import '../../shared/json/json_codec_helpers.dart';
import '../../shared/utils/omnyshell_home.dart';
import 'credential_provider.dart';

/// A persisted login to a single Hub.
///
/// Records how the user authenticates ([method] is `token` or `publicKey`) plus
/// the optional CA path remembered from `--ca`, so later commands to the same
/// Hub need no credential flags. For key auth only the [keyPath] is stored — the
/// Ed25519 seed itself stays in the file the user manages.
class StoredSession {
  /// The principal (login name) this session authenticates as.
  final String principal;

  /// The authentication method: `token` or `publicKey`.
  final String method;

  /// The bearer token, when [method] is `token`.
  final String? token;

  /// Absolute path to the base64 Ed25519 seed file, when [method] is `publicKey`.
  final String? keyPath;

  /// Path to the Hub CA/cert PEM to trust, remembered from `--ca` (optional).
  final String? ca;

  /// Whether commands reusing this session should skip TLS certificate/hostname
  /// verification, remembered from `--insecure-skip-verify` at login time.
  final bool insecureSkipVerify;

  const StoredSession({
    required this.principal,
    required this.method,
    this.token,
    this.keyPath,
    this.ca,
    this.insecureSkipVerify = false,
  });

  /// Creates a token session.
  StoredSession.token({
    required String principal,
    required String token,
    String? ca,
    bool insecureSkipVerify = false,
  }) : this(
         principal: principal,
         method: 'token',
         token: token,
         ca: ca,
         insecureSkipVerify: insecureSkipVerify,
       );

  /// Creates a public-key session referencing the seed file at [keyPath].
  StoredSession.publicKey({
    required String principal,
    required String keyPath,
    String? ca,
    bool insecureSkipVerify = false,
  }) : this(
         principal: principal,
         method: 'publicKey',
         keyPath: keyPath,
         ca: ca,
         insecureSkipVerify: insecureSkipVerify,
       );

  /// Rebuilds the [CredentialProvider] this session describes.
  Future<CredentialProvider> toCredentialProvider() async {
    switch (method) {
      case 'token':
        if (token == null) {
          throw ProtocolException('Stored token session is missing its token');
        }
        return TokenCredentialProvider(principal: principal, token: token!);
      case 'publicKey':
        if (keyPath == null) {
          throw ProtocolException('Stored key session is missing its keyPath');
        }
        final seed = base64.decode(
          base64.normalize(File(keyPath!).readAsStringSync().trim()),
        );
        final keyPair = await Ed25519().newKeyPairFromSeed(seed);
        return PublicKeyCredentialProvider(
          principal: principal,
          keyPair: keyPair,
        );
      default:
        throw ProtocolException("Unknown auth method '$method'");
    }
  }

  Map<String, dynamic> toJson() => {
    'principal': principal,
    'method': method,
    if (token != null) 'token': token,
    if (keyPath != null) 'keyPath': keyPath,
    if (ca != null) 'ca': ca,
    if (insecureSkipVerify) 'insecureSkipVerify': true,
  };

  factory StoredSession.fromJson(Map<String, dynamic> json) => StoredSession(
    principal: Json.requireString(json, 'principal'),
    method: Json.requireString(json, 'method'),
    token: Json.optString(json, 'token'),
    keyPath: Json.optString(json, 'keyPath'),
    ca: Json.optString(json, 'ca'),
    insecureSkipVerify: json['insecureSkipVerify'] == true,
  );
}

/// On-disk store of Hub logins, keyed by Hub URL, with a remembered default.
///
/// Persisted to `<home>/.omnyshell/credentials.json` (file mode `600`). The home
/// directory resolves from `OMNYSHELL_HOME`, then `HOME`, then `USERPROFILE`.
class CredentialStore {
  /// The Hub URL used when a command does not specify `--hub`.
  String? defaultHub;

  /// Saved sessions keyed by Hub URL.
  final Map<String, StoredSession> sessions;

  CredentialStore({this.defaultHub, Map<String, StoredSession>? sessions})
    : sessions = sessions ?? <String, StoredSession>{};

  /// Resolves the credentials file path under [home], defaulting to the home
  /// directory from `OMNYSHELL_HOME`, then `HOME`, then `USERPROFILE`.
  static String path({String? home}) =>
      omnyshellPath(['credentials.json'], home: home);

  /// The saved Hub URLs, sorted, so listings and pickers are stable.
  List<String> get hubs => sessions.keys.toList()..sort();

  /// Every saved Hub URL that [hub] could refer to, sorted.
  ///
  /// Matching widens only while nothing has been found, so a precise answer is
  /// never diluted by a loose one: the key verbatim, then keys that are the
  /// same URL written differently (case, default port, trailing slash), then
  /// keys merely containing [hub] — which lets `foo.example` stand for
  /// `wss://foo.example.com:8080`. Returns an empty list when nothing matches;
  /// more than one entry means [hub] is ambiguous.
  List<String> matchHubs(String hub) {
    final query = hub.trim();
    if (query.isEmpty) return const <String>[];
    if (sessions.containsKey(query)) return <String>[query];

    final normalized = _normalizeHub(query);
    final sameUrl = [
      for (final key in hubs)
        if (_normalizeHub(key) == normalized) key,
    ];
    if (sameUrl.isNotEmpty) return sameUrl;

    final needle = query.toLowerCase();
    return [
      for (final key in hubs)
        if (key.toLowerCase().contains(needle)) key,
    ];
  }

  /// The single saved Hub URL [hub] refers to, or null when it matches none or
  /// is ambiguous — [matchHubs] tells the two apart.
  String? resolveHub(String hub) {
    final matches = matchHubs(hub);
    return matches.length == 1 ? matches.first : null;
  }

  /// Points [defaultHub] at the saved session [hub] refers to.
  ///
  /// Returns the key adopted, or null — leaving [defaultHub] untouched — when
  /// [hub] matches no saved session or more than one. Only a saved session can
  /// become the default: the store would otherwise name a Hub it cannot
  /// authenticate to.
  String? selectDefaultHub(String hub) {
    final key = resolveHub(hub);
    if (key != null) defaultHub = key;
    return key;
  }

  /// Rewrites [hub] to the form two spellings of the same Hub share: lowercase
  /// scheme and host, the port always explicit, and no trailing slash. A URL
  /// that will not parse is compared as written.
  static String _normalizeHub(String hub) {
    Uri uri;
    try {
      uri = Uri.parse(hub);
    } on FormatException {
      return hub;
    }
    if (!uri.hasScheme) {
      // A bare "host:port/path" parses as a scheme-less URI whose authority is
      // empty; re-parse it as wss, the scheme every Hub URL uses.
      try {
        uri = Uri.parse('wss://$hub');
      } on FormatException {
        return hub;
      }
    }
    if (uri.host.isEmpty) return hub;
    final scheme = uri.scheme.toLowerCase();
    final port = uri.hasPort ? uri.port : _defaultPort(scheme);
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '$scheme://${uri.host.toLowerCase()}:$port$path';
  }

  static int _defaultPort(String scheme) => switch (scheme) {
    'ws' || 'http' => 80,
    'wss' || 'https' => 443,
    _ => 0,
  };

  /// Loads the store, returning an empty one when no file exists yet.
  static Future<CredentialStore> load({String? home}) async {
    final file = File(path(home: home));
    if (!await file.exists()) return CredentialStore();
    final json = Json.asObject(
      jsonDecode(await file.readAsString()),
      'credentials file',
    );
    final sessions = <String, StoredSession>{};
    final raw = json['sessions'];
    if (raw is Map) {
      raw.forEach((hub, value) {
        sessions[hub.toString()] = StoredSession.fromJson(
          Json.asObject(value, 'session'),
        );
      });
    }
    return CredentialStore(
      defaultHub: Json.optString(json, 'defaultHub'),
      sessions: sessions,
    );
  }

  /// Persists the store, creating `~/.omnyshell` (mode `700`) and writing the
  /// file with mode `600` on POSIX systems.
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

  Map<String, dynamic> toJson() => {
    if (defaultHub != null) 'defaultHub': defaultHub,
    'sessions': {
      for (final entry in sessions.entries) entry.key: entry.value.toJson(),
    },
  };

  static Future<void> _chmod(String path, String mode) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', [mode, path]);
  }
}
