import '../entities/node_descriptor.dart';
import '../entities/session.dart';
import 'principal.dart';

/// Decides whether an authenticated [Principal] may open a session on a node.
///
/// Enforced by the Hub on every `session.open`. Implementations can key off the
/// principal's roles, the node's labels, the requested [SessionMode], or any
/// external policy source.
abstract class Authorizer {
  /// Whether [principal] may open a session in [mode] on [node].
  Future<bool> canOpenSession({
    required Principal principal,
    required NodeDescriptor node,
    required SessionMode mode,
  });
}

/// A role-based [Authorizer] with a small, predictable policy:
///
/// - principals with the `admin` role may open sessions on any node;
/// - otherwise the principal must hold a role listed in the node's
///   `allow-roles` label (a comma-separated list), e.g. `allow-roles: developer,ci`;
/// - a node with no `allow-roles` label is admin-only.
///
/// This ships as the Hub default so authorization fails closed.
class RoleBasedAuthorizer implements Authorizer {
  /// The role that grants access to every node.
  final String adminRole;

  /// The node label whose value lists the roles allowed on that node.
  final String allowRolesLabel;

  /// Creates a role-based authorizer.
  const RoleBasedAuthorizer({
    this.adminRole = 'admin',
    this.allowRolesLabel = 'allow-roles',
  });

  @override
  Future<bool> canOpenSession({
    required Principal principal,
    required NodeDescriptor node,
    required SessionMode mode,
  }) async {
    if (principal.hasRole(adminRole)) return true;
    final raw = node.labels[allowRolesLabel];
    if (raw == null || raw.trim().isEmpty) return false;
    final allowed = raw
        .split(',')
        .map((r) => r.trim())
        .where((r) => r.isNotEmpty)
        .toSet();
    return principal.roles.any(allowed.contains);
  }
}
