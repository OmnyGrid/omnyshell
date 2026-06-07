import 'package:meta/meta.dart';

import '../value_objects/principal_id.dart';

/// An authenticated identity, as resolved by an [Authenticator].
///
/// A principal may be a human user or a node account. [roles] drive
/// authorization decisions (e.g. `admin`, `developer`, `ci`, `node`).
@immutable
class Principal {
  /// The principal's stable identity.
  final PrincipalId id;

  /// A human-friendly display name.
  final String displayName;

  /// The roles granted to this principal.
  final Set<String> roles;

  /// Creates a principal.
  const Principal({
    required this.id,
    required this.displayName,
    this.roles = const {},
  });

  /// Whether the principal holds [role].
  bool hasRole(String role) => roles.contains(role);

  /// Serializes to a JSON map (used by `whoami` and audit records).
  Map<String, dynamic> toJson() => {
    'id': id.value,
    'displayName': displayName,
    'roles': roles.toList()..sort(),
  };
}
