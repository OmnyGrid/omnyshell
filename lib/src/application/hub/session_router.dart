import '../../domain/auth/principal.dart';
import '../../domain/entities/session.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/session_id.dart';
import 'hub_peer.dart';

/// A live route bridging a client-side channel to a node-side channel for one
/// brokered session. The Hub relays bytes by rewriting the channel id between
/// the two ends.
class SessionRoute {
  /// The session id.
  final SessionId sessionId;

  /// The target node.
  final NodeId nodeId;

  /// The principal that opened the session.
  final Principal principal;

  /// Exec or interactive shell.
  final SessionMode mode;

  /// The client peer connection.
  final HubPeer client;

  /// The channel id on the client connection.
  final int clientChannel;

  /// The node peer connection.
  final HubPeer node;

  /// The channel id on the node connection.
  final int nodeChannel;

  /// A per-session secret minted by the Hub (hijack protection / direct-mode
  /// grant binding).
  final String perSessionToken;

  /// Current lifecycle state.
  SessionState state;

  /// Creates a session route.
  SessionRoute({
    required this.sessionId,
    required this.nodeId,
    required this.principal,
    required this.mode,
    required this.client,
    required this.clientChannel,
    required this.node,
    required this.nodeChannel,
    required this.perSessionToken,
    this.state = SessionState.opening,
  });
}

/// Holds the Hub's live session routes with O(1) lookup from either end and by
/// session id.
class SessionRouter {
  final Map<String, SessionRoute> _byClient = {};
  final Map<String, SessionRoute> _byNode = {};
  final Map<String, SessionRoute> _bySession = {};

  static String _key(String connId, int channel) => '$connId#$channel';

  /// All live routes.
  Iterable<SessionRoute> get all => _bySession.values;

  /// Registers a [route].
  void add(SessionRoute route) {
    _byClient[_key(route.client.id, route.clientChannel)] = route;
    _byNode[_key(route.node.id, route.nodeChannel)] = route;
    _bySession[route.sessionId.value] = route;
  }

  /// The route for a client-side `(connId, channel)`, or `null`.
  SessionRoute? byClient(String connId, int channel) =>
      _byClient[_key(connId, channel)];

  /// The route for a node-side `(connId, channel)`, or `null`.
  SessionRoute? byNode(String connId, int channel) =>
      _byNode[_key(connId, channel)];

  /// The route with [sessionId], or `null`.
  SessionRoute? bySession(SessionId sessionId) => _bySession[sessionId.value];

  /// Removes and returns the route with [sessionId], if present.
  SessionRoute? remove(SessionId sessionId) {
    final route = _bySession.remove(sessionId.value);
    if (route != null) {
      _byClient.remove(_key(route.client.id, route.clientChannel));
      _byNode.remove(_key(route.node.id, route.nodeChannel));
    }
    return route;
  }

  /// Removes and returns every route touching the peer connection [peerId]
  /// (used when a client or node disconnects).
  List<SessionRoute> removeForPeer(String peerId) {
    final affected = _bySession.values
        .where((r) => r.client.id == peerId || r.node.id == peerId)
        .toList();
    for (final route in affected) {
      remove(route.sessionId);
    }
    return affected;
  }
}
