import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import 'installation.dart';

/// The newest stable version of [package] on the repository at [source]
/// (pub.dev's API, which private repositories implement too), or `null` when
/// it cannot be told. [client] is closed by the caller.
Future<String?> latestHostedVersion(
  String package,
  HostedSource source, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final base = source.url.endsWith('/')
      ? source.url.substring(0, source.url.length - 1)
      : source.url;
  final own = client == null;
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(
          Uri.parse('$base/api/packages/$package'),
          headers: const {'Accept': 'application/vnd.pub.v2+json'},
        )
        .timeout(timeout);
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    final latest = body is Map ? body['latest'] : null;
    final version = latest is Map ? latest['version'] : null;
    return version is String ? version : null;
  } on Object {
    return null;
  } finally {
    if (own) c.close();
  }
}

/// Whether [candidate] is a newer version than [installed]. Unparseable
/// versions compare as not newer.
bool isNewerVersion(String candidate, String installed) {
  try {
    return Version.parse(candidate) > Version.parse(installed);
  } on FormatException {
    return false;
  }
}
