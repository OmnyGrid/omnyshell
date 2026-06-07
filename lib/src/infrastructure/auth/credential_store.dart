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

  const StoredSession({
    required this.principal,
    required this.method,
    this.token,
    this.keyPath,
    this.ca,
  });

  /// Creates a token session.
  StoredSession.token({
    required String principal,
    required String token,
    String? ca,
  }) : this(principal: principal, method: 'token', token: token, ca: ca);

  /// Creates a public-key session referencing the seed file at [keyPath].
  StoredSession.publicKey({
    required String principal,
    required String keyPath,
    String? ca,
  }) : this(
         principal: principal,
         method: 'publicKey',
         keyPath: keyPath,
         ca: ca,
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
  };

  factory StoredSession.fromJson(Map<String, dynamic> json) => StoredSession(
    principal: Json.requireString(json, 'principal'),
    method: Json.requireString(json, 'method'),
    token: Json.optString(json, 'token'),
    keyPath: Json.optString(json, 'keyPath'),
    ca: Json.optString(json, 'ca'),
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
