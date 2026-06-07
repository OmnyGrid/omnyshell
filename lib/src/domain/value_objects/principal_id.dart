import '../../shared/errors/omnyshell_exception.dart';

/// Identity of an authenticated principal (a user or a node account) as known
/// to the Hub. Equality is by [value].
class PrincipalId {
  /// The raw identifier string.
  final String value;

  /// Creates and validates a principal id.
  ///
  /// Throws [ProtocolException] if [value] is empty.
  factory PrincipalId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const ProtocolException('Principal id cannot be empty');
    }
    return PrincipalId._(trimmed);
  }

  const PrincipalId._(this.value);

  @override
  bool operator ==(Object other) =>
      other is PrincipalId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
