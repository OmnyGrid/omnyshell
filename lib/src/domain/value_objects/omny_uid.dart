import '../../shared/errors/omnyshell_exception.dart';

/// A deterministic, globally-stable identifier for a node or a hub.
///
/// The value is a short prefix (`nod_` for nodes, `hub_` for hubs) followed by
/// the URL-safe base64 of a SHA-256 digest of the entity's identity material
/// (cryptographic key + stable hardware/platform attributes). Because the
/// alphabet is `[A-Za-z0-9_-]` plus the `_` separator, every [OmnyUid] is also a
/// valid [NodeId]. Equality is by [value].
class OmnyUid {
  /// The node UID prefix.
  static const String nodePrefix = 'nod_';

  /// The hub UID prefix.
  static const String hubPrefix = 'hub_';

  /// The full identifier string, including its prefix.
  final String value;

  const OmnyUid._(this.value);

  /// Wraps and validates a UID [value].
  ///
  /// Throws [ProtocolException] unless [value] starts with a known prefix and
  /// contains only `[A-Za-z0-9_-]`.
  factory OmnyUid(String value) {
    final trimmed = value.trim();
    final hasPrefix =
        trimmed.startsWith(nodePrefix) || trimmed.startsWith(hubPrefix);
    if (!hasPrefix || !_valid.hasMatch(trimmed)) {
      throw ProtocolException('Invalid UID: "$value"');
    }
    return OmnyUid._(trimmed);
  }

  static final RegExp _valid = RegExp(r'^[A-Za-z0-9_-]+$');

  /// Whether this UID identifies a node.
  bool get isNode => value.startsWith(nodePrefix);

  /// Whether this UID identifies a hub.
  bool get isHub => value.startsWith(hubPrefix);

  @override
  bool operator ==(Object other) => other is OmnyUid && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
