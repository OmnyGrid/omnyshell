import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// What a node can do, advertised to the Hub after registration and relayed to
/// clients during discovery.
@immutable
class NodeCapabilities {
  /// Shells the node can launch (e.g. `bash`, `sh`, `pwsh`).
  final List<String> shells;

  /// Named features the node supports (e.g. `exec`, `shell`, `resize`,
  /// `signals`).
  final List<String> features;

  /// Maximum number of concurrent sessions the node will accept.
  final int maxSessions;

  /// Optional directly-reachable endpoint (`host:port`) for the direct-resolution
  /// connection strategy. `null` means the node is only reachable via the Hub
  /// tunnel.
  final String? directEndpoint;

  /// Creates node capabilities.
  const NodeCapabilities({
    required this.shells,
    required this.features,
    required this.maxSessions,
    this.directEndpoint,
  });

  /// A conservative default: a single login shell, exec + interactive support,
  /// file transfer and OmnyDrive mounts, tunnel-only, modest session cap.
  factory NodeCapabilities.defaults({List<String>? shells}) => NodeCapabilities(
    shells: shells ?? const ['sh'],
    features: const ['exec', 'shell', 'signals', 'transfer', 'drive', 'tunnel'],
    maxSessions: 50,
  );

  /// Whether the named [feature] is supported.
  bool supports(String feature) => features.contains(feature);

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'shells': shells,
    'features': features,
    'maxSessions': maxSessions,
    if (directEndpoint != null) 'directEndpoint': directEndpoint,
  };

  /// Decodes from a JSON map.
  static NodeCapabilities fromJson(Map<String, dynamic> json) =>
      NodeCapabilities(
        shells: Json.optStringList(json, 'shells'),
        features: Json.optStringList(json, 'features'),
        maxSessions: Json.optInt(json, 'maxSessions', 50)!,
        directEndpoint: Json.optString(json, 'directEndpoint'),
      );
}
