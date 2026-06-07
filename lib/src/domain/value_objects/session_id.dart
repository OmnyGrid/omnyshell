import '../../shared/errors/omnyshell_exception.dart';
import '../../shared/utils/id_generator.dart';

/// Unique identity of a brokered session, minted by the Hub when a session is
/// opened. Equality is by [value].
class SessionId {
  /// The raw identifier string (a UUID when generated).
  final String value;

  /// Wraps an existing session id [value].
  ///
  /// Throws [ProtocolException] if [value] is empty.
  factory SessionId(String value) {
    if (value.trim().isEmpty) {
      throw const ProtocolException('Session id cannot be empty');
    }
    return SessionId._(value);
  }

  const SessionId._(this.value);

  /// Mints a fresh, random session id.
  factory SessionId.generate() => SessionId._(newId());

  @override
  bool operator ==(Object other) => other is SessionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
