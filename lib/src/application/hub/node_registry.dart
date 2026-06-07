import '../../domain/entities/node_capabilities.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../domain/value_objects/node_id.dart';
import 'hub_peer.dart';

/// A node currently registered with the Hub, with its live connection and
/// liveness bookkeeping.
class RegisteredNode {
  /// The node's public descriptor (identity, platform, labels, capabilities,
  /// online flag).
  NodeDescriptor descriptor;

  /// The peer connection serving this node.
  HubPeer peer;

  /// The last accepted heartbeat sequence number (monotonic).
  int lastHeartbeatSeq;

  /// When the Hub last heard from the node.
  DateTime lastSeen;

  /// Number of sessions currently routed to this node.
  int activeSessions;

  /// Creates a registered-node record.
  RegisteredNode({
    required this.descriptor,
    required this.peer,
    required this.lastSeen,
    this.lastHeartbeatSeq = 0,
    this.activeSessions = 0,
  });

  /// The node's id.
  NodeId get id => descriptor.id;
}

/// Tracks the nodes registered with the Hub and answers discovery queries.
class NodeRegistry {
  final Map<String, RegisteredNode> _byId = {};

  /// All registered nodes.
  Iterable<RegisteredNode> get all => _byId.values;

  /// Registers (or re-registers) a node, replacing any prior record.
  RegisteredNode register({
    required NodeDescriptor descriptor,
    required HubPeer peer,
    required DateTime now,
  }) {
    final node = RegisteredNode(
      descriptor: descriptor.copyWith(online: true),
      peer: peer,
      lastSeen: now,
    );
    _byId[descriptor.id.value] = node;
    return node;
  }

  /// The node with [id], or `null`.
  RegisteredNode? byId(NodeId id) => _byId[id.value];

  /// The node served by the peer connection [peerId], or `null`.
  RegisteredNode? byPeerId(String peerId) {
    for (final node in _byId.values) {
      if (node.peer.id == peerId) return node;
    }
    return null;
  }

  /// Updates a node's advertised [capabilities].
  void updateCapabilities(NodeId id, NodeCapabilities capabilities) {
    final node = _byId[id.value];
    if (node != null) {
      node.descriptor = node.descriptor.copyWith(capabilities: capabilities);
    }
  }

  /// Records an accepted heartbeat.
  void recordHeartbeat({
    required NodeId id,
    required int seq,
    required int activeSessions,
    required DateTime now,
  }) {
    final node = _byId[id.value];
    if (node != null) {
      node.lastHeartbeatSeq = seq;
      node.activeSessions = activeSessions;
      node.lastSeen = now;
    }
  }

  /// Removes the node with [id] from the registry, returning the removed
  /// record if present.
  RegisteredNode? remove(NodeId id) => _byId.remove(id.value);

  /// Returns descriptors for discovery, applying an optional label [filter]
  /// (each `key=value` must match the node's labels).
  List<NodeDescriptor> list({Map<String, String> filter = const {}}) {
    final result = <NodeDescriptor>[];
    for (final node in _byId.values) {
      if (_matches(node.descriptor, filter)) result.add(node.descriptor);
    }
    result.sort((a, b) => a.id.value.compareTo(b.id.value));
    return result;
  }

  bool _matches(NodeDescriptor descriptor, Map<String, String> filter) {
    for (final entry in filter.entries) {
      if (entry.key == 'platform') {
        if (descriptor.platform.os != entry.value) return false;
        continue;
      }
      if (descriptor.labels[entry.key] != entry.value) return false;
    }
    return true;
  }
}
