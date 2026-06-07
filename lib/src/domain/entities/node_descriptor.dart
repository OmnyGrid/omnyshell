import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import '../value_objects/node_id.dart';
import '../value_objects/omny_uid.dart';
import 'node_capabilities.dart';
import 'platform_info.dart';

/// A node's public description as registered with the Hub and returned by
/// discovery (`nodes list`). Combines identity, platform, operator labels and
/// advertised capabilities.
@immutable
class NodeDescriptor {
  /// The node's stable identity.
  final NodeId id;

  /// The node's deterministic global UID (cryptographic key + hardware/platform
  /// fingerprint), or `null` if the node did not report one.
  final OmnyUid? uid;

  /// A human-friendly display name.
  final String displayName;

  /// The node's platform (OS, arch, agent version, hostname).
  final PlatformInfo platform;

  /// Free-form operator labels (e.g. `{env: prod, region: eu}`), used for
  /// discovery filtering and authorization policy.
  final Map<String, String> labels;

  /// Whether the node currently holds a live connection to the Hub.
  final bool online;

  /// The node's advertised capabilities, if it has registered them.
  final NodeCapabilities? capabilities;

  /// Creates a node descriptor.
  const NodeDescriptor({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.online,
    this.uid,
    this.labels = const {},
    this.capabilities,
  });

  /// Returns a copy with selected fields replaced.
  NodeDescriptor copyWith({
    bool? online,
    NodeCapabilities? capabilities,
    Map<String, String>? labels,
  }) => NodeDescriptor(
    id: id,
    uid: uid,
    displayName: displayName,
    platform: platform,
    online: online ?? this.online,
    labels: labels ?? this.labels,
    capabilities: capabilities ?? this.capabilities,
  );

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'nodeId': id.value,
    if (uid != null) 'uid': uid!.value,
    'displayName': displayName,
    'platform': platform.toJson(),
    'labels': labels,
    'online': online,
    if (capabilities != null) 'capabilities': capabilities!.toJson(),
  };

  /// Decodes from a JSON map.
  static NodeDescriptor fromJson(Map<String, dynamic> json) {
    final caps = json['capabilities'];
    final uidValue = Json.optString(json, 'uid');
    return NodeDescriptor(
      id: NodeId(Json.requireString(json, 'nodeId')),
      uid: uidValue == null ? null : OmnyUid(uidValue),
      displayName: Json.optString(json, 'displayName') ?? '',
      platform: PlatformInfo.fromJson(Json.asObject(json['platform'])),
      labels: Json.optStringMap(json, 'labels'),
      online: Json.optBool(json, 'online'),
      capabilities: caps == null
          ? null
          : NodeCapabilities.fromJson(Json.asObject(caps)),
    );
  }
}
