import '../../domain/auth/principal.dart';
import '../../domain/value_objects/node_id.dart';
import '../../protocol/omnyshell_connection.dart';
import '../../shared/utils/id_generator.dart';

/// The role a peer claimed in its `hello`.
enum PeerRole {
  /// Awaiting the peer's `hello` (role not yet known).
  unknown,

  /// A node serving sessions.
  node,

  /// A client opening sessions.
  client,
}

/// The Hub's per-connection state for one accepted peer.
///
/// Tracks the connection, the single-use challenge nonce issued to it, its role
/// and (once authenticated) its [Principal]. For node peers it also allocates
/// node-side channel ids used by the relay.
class HubPeer {
  /// A unique id for this connection (used to key routes).
  final String id;

  /// The underlying connection.
  final OmnyShellConnection connection;

  /// The base64 challenge nonce issued to this peer in the Hub's `hello`.
  final String nonce;

  /// The peer's claimed role.
  PeerRole role = PeerRole.unknown;

  /// The authenticated principal, once `auth.request` succeeds.
  Principal? principal;

  /// The node id, once a node peer has registered.
  NodeId? nodeId;

  int _nextChannel = 1;

  /// The first id [allocateReverseChannel] hands out. Hub-initiated channels
  /// toward a *client* peer must not collide with ids the client allocates for
  /// its own sessions (which start at 1), so they live in a disjoint high range.
  static const int _reverseChannelBase = 0x40000000;
  int _nextReverseChannel = _reverseChannelBase;

  /// Creates a peer over [connection] with the issued [nonce].
  HubPeer({required this.connection, required this.nonce}) : id = newId();

  /// Whether the peer has authenticated.
  bool get isAuthenticated => principal != null;

  /// Allocates the next node-side channel id (node peers only).
  int allocateChannel() => _nextChannel++;

  /// Allocates a channel id for a Hub-initiated channel toward a *client* peer
  /// (e.g. a tunnel that exposes the client's own machine), from a disjoint
  /// range so it never collides with the client's own session channel ids.
  int allocateReverseChannel() => _nextReverseChannel++;
}
