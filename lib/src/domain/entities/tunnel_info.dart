import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// A user-facing view of an active TCP tunnel held by the Hub, as returned by
/// the list API and relayed to the owning client.
///
/// A tunnel publishes an internal `targetHost:targetPort` (reachable by the
/// exposer — a node or the client's own machine) on a public `publicPort` the
/// Hub listens on. External TCP connections to `publicHost:publicPort` are
/// bridged to the target over the exposer's multiplexed connection.
@immutable
class TunnelInfo {
  /// The full, cryptographically-secure tunnel id.
  final String tunnelId;

  /// The node that exposes the target, or `@local` when the owning client
  /// exposes its own machine.
  final String nodeId;

  /// The authenticated principal that owns the tunnel.
  final String ownerUserId;

  /// The internal host the exposer dials for each connection.
  final String targetHost;

  /// The internal TCP port the exposer dials for each connection.
  final int targetPort;

  /// The host the Hub advertises for the public listener (may be empty/wildcard,
  /// in which case clients substitute the Hub's own hostname).
  final String publicHost;

  /// The public TCP port the Hub listens on for this tunnel.
  final int publicPort;

  /// Whether the public port terminates TLS (HTTPS).
  final bool secure;

  /// When the tunnel was opened.
  final DateTime createdAt;

  /// Creates a tunnel view.
  const TunnelInfo({
    required this.tunnelId,
    required this.nodeId,
    required this.ownerUserId,
    required this.targetHost,
    required this.targetPort,
    required this.publicHost,
    required this.publicPort,
    required this.createdAt,
    this.secure = false,
  });

  /// A short, display-only handle derived from [tunnelId]. Close accepts any
  /// unambiguous prefix of [tunnelId] (the short id being one such).
  String get shortId =>
      tunnelId.length <= 8 ? tunnelId : tunnelId.substring(0, 8);

  /// Encodes this info to a JSON map.
  Map<String, dynamic> toJson() => {
    'tunnelId': tunnelId,
    'nodeId': nodeId,
    'ownerUserId': ownerUserId,
    'targetHost': targetHost,
    'targetPort': targetPort,
    'publicHost': publicHost,
    'publicPort': publicPort,
    if (secure) 'secure': true,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  /// Decodes a [TunnelInfo] from a JSON map.
  static TunnelInfo fromJson(Map<String, dynamic> d) => TunnelInfo(
    tunnelId: Json.requireString(d, 'tunnelId'),
    nodeId: Json.requireString(d, 'nodeId'),
    ownerUserId: Json.optString(d, 'ownerUserId') ?? '',
    targetHost: Json.optString(d, 'targetHost') ?? 'localhost',
    targetPort: Json.requireInt(d, 'targetPort'),
    publicHost: Json.optString(d, 'publicHost') ?? '',
    publicPort: Json.requireInt(d, 'publicPort'),
    secure: Json.optBool(d, 'secure'),
    createdAt: Json.requireTimestamp(d, 'createdAt'),
  );
}
