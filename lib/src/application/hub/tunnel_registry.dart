import 'dart:io';

import '../../domain/auth/principal.dart';
import '../../domain/entities/tunnel_info.dart';

/// A live tunnel held by the Hub: a public [serverSocket] whose accepted
/// connections are bridged to [targetHost]:[targetPort] over the exposer's
/// connection.
class TunnelRegistration {
  /// The minted tunnel id.
  final String tunnelId;

  /// The connection id of the client that owns (requested) the tunnel.
  final String ownerConnId;

  /// The connection id of the exposer — the node's peer, or (for a `@local`
  /// tunnel) the owning client itself.
  final String exposerConnId;

  /// The principal that owns the tunnel.
  final Principal owner;

  /// The exposer node id, or [TunnelRegistration.localNode].
  final String nodeId;

  /// The internal host the exposer dials for each connection.
  final String targetHost;

  /// The internal TCP port the exposer dials for each connection.
  final int targetPort;

  /// The host the Hub advertises for the public listener.
  final String publicHost;

  /// The public TCP port the Hub listens on.
  final int publicPort;

  /// The bound public listener.
  final ServerSocket serverSocket;

  /// Whether the public port terminates TLS (HTTPS). When true, accepted
  /// connections are upgraded with the Hub's tunnel TLS context before bridging.
  final bool secure;

  /// When the tunnel was opened.
  final DateTime createdAt;

  /// The `@local` sentinel node id (the owning client's own machine).
  static const String localNode = '@local';

  /// Creates a tunnel registration.
  TunnelRegistration({
    required this.tunnelId,
    required this.ownerConnId,
    required this.exposerConnId,
    required this.owner,
    required this.nodeId,
    required this.targetHost,
    required this.targetPort,
    required this.publicHost,
    required this.publicPort,
    required this.serverSocket,
    required this.createdAt,
    this.secure = false,
  });

  /// A wire-safe view of this tunnel.
  TunnelInfo toInfo() => TunnelInfo(
    tunnelId: tunnelId,
    nodeId: nodeId,
    ownerUserId: owner.id.value,
    targetHost: targetHost,
    targetPort: targetPort,
    publicHost: publicHost,
    publicPort: publicPort,
    secure: secure,
    createdAt: createdAt,
  );
}

/// The Hub's table of active tunnels plus the set of public ports in use, so
/// allocation and specific-port validation are O(1).
class TunnelRegistry {
  final Map<String, TunnelRegistration> _byId = {};
  final Set<int> _usedPorts = {};

  /// All active tunnels.
  Iterable<TunnelRegistration> get all => _byId.values;

  /// Whether [port] is currently bound by a tunnel.
  bool isPortInUse(int port) => _usedPorts.contains(port);

  /// Registers [reg] and marks its public port in use.
  void add(TunnelRegistration reg) {
    _byId[reg.tunnelId] = reg;
    _usedPorts.add(reg.publicPort);
  }

  /// The tunnel with [tunnelId], or `null`.
  TunnelRegistration? byId(String tunnelId) => _byId[tunnelId];

  /// Removes and returns the tunnel with [tunnelId], freeing its port.
  TunnelRegistration? remove(String tunnelId) {
    final reg = _byId.remove(tunnelId);
    if (reg != null) _usedPorts.remove(reg.publicPort);
    return reg;
  }

  /// Tunnels owned by the principal [principalId]. Ownership is by principal —
  /// not by connection — so a node-exposed tunnel outlives the requesting client
  /// and can be listed/closed from a later connection of the same user.
  List<TunnelRegistration> ownedByPrincipal(String principalId) =>
      _byId.values.where((r) => r.owner.id.value == principalId).toList();

  /// Tunnels whose exposer is the connection [connId]. When the exposer drops
  /// the tunnel can no longer be served and must be torn down.
  List<TunnelRegistration> exposedBy(String connId) =>
      _byId.values.where((r) => r.exposerConnId == connId).toList();

  /// Resolves a tunnel by full id or unambiguous prefix among [principalId]'s
  /// owned tunnels. Returns `null` when there is no match or the prefix is
  /// ambiguous.
  TunnelRegistration? resolveOwned(String principalId, String ref) {
    final owned = ownedByPrincipal(principalId);
    for (final r in owned) {
      if (r.tunnelId == ref) return r;
    }
    final matches = owned.where((r) => r.tunnelId.startsWith(ref)).toList();
    return matches.length == 1 ? matches.first : null;
  }
}
