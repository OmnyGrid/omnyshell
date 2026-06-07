import '../../shared/errors/omnyshell_exception.dart';

/// Stable identity of a node, used by clients to address it (instead of a
/// `host:port`). Equality is by [value].
///
/// A node id is a non-empty, trimmed token (letters, digits, `_`, `-`, `.`).
/// It is supplied by the node operator and registered with the Hub.
class NodeId {
  /// The raw identifier string.
  final String value;

  /// Creates and validates a node id.
  ///
  /// Throws [ProtocolException] if [value] is empty or contains characters
  /// outside `[A-Za-z0-9_.-]`.
  factory NodeId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const ProtocolException('Node id cannot be empty');
    }
    if (!_valid.hasMatch(trimmed)) {
      throw ProtocolException('Invalid node id: "$value"');
    }
    return NodeId._(trimmed);
  }

  const NodeId._(this.value);

  static final RegExp _valid = RegExp(r'^[A-Za-z0-9_.-]+$');

  @override
  bool operator ==(Object other) => other is NodeId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
