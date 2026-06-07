import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/auth/authenticator.dart';
import '../../domain/auth/authorizer.dart';
import '../../domain/auth/credential.dart';
import '../../domain/entities/session.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/session_id.dart';
import '../../protocol/control_message.dart';
import '../../protocol/omnyshell_connection.dart';
import '../../protocol/omnyshell_frame.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/errors/error_codes.dart';
import '../../shared/errors/omnyshell_exception.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/id_generator.dart';
import 'audit_log.dart';
import 'heartbeat_monitor.dart';
import 'hub_peer.dart';
import 'node_registry.dart';
import 'session_router.dart';

/// The brain of the Hub: authenticates peers, registers nodes, authorizes and
/// brokers sessions, and relays session bytes between clients and nodes.
///
/// Transport-agnostic — it is driven by [accept]ing [OmnyShellConnection]s, so
/// it can run over the real TLS WebSocket endpoint or an in-memory loopback in
/// tests. The default relay strategy is the NAT-friendly tunnel: session frames
/// are forwarded over the node's persistent connection with their channel id
/// rewritten between the two ends.
class HubBroker {
  /// Authenticates node and client credentials.
  final Authenticator authenticator;

  /// Authorizes session opens.
  final Authorizer authorizer;

  /// The node registry.
  final NodeRegistry registry;

  /// The session routing table.
  final SessionRouter router;

  /// The audit log.
  final AuditLog audit;

  /// The clock (also used by the heartbeat monitor).
  final Clock clock;

  /// How long a node may go silent before being declared offline.
  final Duration heartbeatTimeout;

  /// Optional diagnostic logger.
  final void Function(String message)? logger;

  late final HeartbeatMonitor _monitor;
  final Map<String, HubPeer> _peers = {};

  /// Creates a hub broker.
  HubBroker({
    required this.authenticator,
    required this.authorizer,
    NodeRegistry? registry,
    SessionRouter? router,
    AuditLog? audit,
    this.clock = const SystemClock(),
    this.heartbeatTimeout = const Duration(seconds: 30),
    this.logger,
  }) : registry = registry ?? NodeRegistry(),
       router = router ?? SessionRouter(),
       audit = audit ?? AuditLog() {
    _monitor = HeartbeatMonitor(
      registry: this.registry,
      clock: clock,
      timeout: heartbeatTimeout,
      onTimeout: _onNodeTimeout,
    );
  }

  /// Starts the liveness watchdog.
  void start() => _monitor.start();

  /// Stops the watchdog and closes every peer connection so nodes and clients
  /// observe the shutdown (and nodes begin reconnecting).
  void stop() {
    _monitor.stop();
    for (final peer in _peers.values.toList()) {
      unawaited(peer.connection.close(4503, 'hub stopping'));
    }
    _peers.clear();
  }

  /// The heartbeat monitor (exposed for manual ticking in tests).
  HeartbeatMonitor get monitor => _monitor;

  /// Accepts a newly-connected peer, issues the challenge `hello`, and begins
  /// handling its frames.
  void accept(OmnyShellConnection connection) {
    final peer = HubPeer(connection: connection, nonce: newSecureToken());
    _peers[peer.id] = peer;
    connection.send(
      ControlFrame(
        Hello(
          role: 'hub',
          protocolVersion: kProtocolVersion,
          minVersion: kMinProtocolVersion,
          nonce: peer.nonce,
        ),
      ),
    );
    connection.incoming.listen(
      (frame) => _onFrame(peer, frame),
      onDone: () => _onPeerGone(peer),
      onError: (Object _) => _onPeerGone(peer),
      cancelOnError: false,
    );
  }

  // --- Frame dispatch -------------------------------------------------------

  void _onFrame(HubPeer peer, OmnyShellFrame frame) {
    switch (frame) {
      case ControlFrame(message: final m):
        _onControl(peer, m);
      case final DataFrame f:
        _onData(peer, f);
    }
  }

  Future<void> _onControl(HubPeer peer, ControlMessage message) async {
    if (!peer.isAuthenticated) {
      switch (message) {
        case final Hello hello:
          peer.role = _roleFrom(hello.role);
          if (!isProtocolCompatible(
            hello.protocolVersion,
            remoteMin: hello.minVersion,
          )) {
            _fail(peer, ErrorCodes.versionMismatch, 'Incompatible protocol');
          }
        case final AuthRequest auth:
          await _handleAuth(peer, auth);
        default:
          _fail(peer, ErrorCodes.notAuthenticated, 'Authentication required');
      }
      return;
    }

    // Authenticated peers.
    if (message is Ping) {
      peer.connection.send(
        ControlFrame(
          Pong(id: message.id, ts: message.ts, serverTs: clock.now()),
        ),
      );
      return;
    }

    switch (peer.role) {
      case PeerRole.node:
        await _onNodeControl(peer, message);
      case PeerRole.client:
        await _onClientControl(peer, message);
      case PeerRole.unknown:
        _fail(peer, ErrorCodes.protocolError, 'Unknown peer role');
    }
  }

  void _onData(HubPeer peer, DataFrame frame) {
    if (!peer.isAuthenticated) return;
    if (peer.role == PeerRole.client) {
      final route = router.byClient(peer.id, frame.channel);
      if (route != null) {
        route.node.connection.send(_reChannelData(frame, route.nodeChannel));
      }
    } else if (peer.role == PeerRole.node) {
      final route = router.byNode(peer.id, frame.channel);
      if (route != null) {
        route.client.connection.send(
          _reChannelData(frame, route.clientChannel),
        );
      }
    }
  }

  // --- Authentication -------------------------------------------------------

  Future<void> _handleAuth(HubPeer peer, AuthRequest request) async {
    final credential = _credentialFrom(request);
    if (credential == null) {
      _fail(peer, ErrorCodes.authFailed, 'Unsupported auth method');
      return;
    }
    final challenge = Uint8List.fromList(utf8.encode(peer.nonce));
    try {
      final principal = await authenticator.authenticate(
        credential,
        challenge: challenge,
      );
      peer.principal = principal;
      audit.record(
        'auth.ok',
        principal: principal.id.value,
        detail: {'method': request.method, 'role': peer.role.name},
      );
      peer.connection.send(
        ControlFrame(
          AuthOk(
            principal: principal.id.value,
            displayName: principal.displayName,
            roles: principal.roles.toList()..sort(),
            sessionToken: newSecureToken(),
          ),
        ),
      );
    } on AuthException catch (e) {
      audit.record(
        'auth.fail',
        principal: request.principal,
        detail: {'reason': e.message},
      );
      peer.connection.send(
        ControlFrame(AuthFail(reason: 'auth_failed', message: e.message)),
      );
      await peer.connection.close(4401, 'unauthorized');
    }
  }

  Credential? _credentialFrom(AuthRequest request) {
    switch (request.method) {
      case 'token':
        final token = request.token;
        if (token == null) return null;
        return TokenCredential(principal: request.principal, token: token);
      case 'publicKey':
        final key = request.publicKey;
        final sig = request.signature;
        if (key == null || sig == null) return null;
        return PublicKeyCredential(
          principal: request.principal,
          publicKeyBase64: key,
          signatureBase64: sig,
        );
      default:
        return null;
    }
  }

  // --- Node-role handling ---------------------------------------------------

  Future<void> _onNodeControl(HubPeer peer, ControlMessage message) async {
    switch (message) {
      case final NodeRegister reg:
        final descriptor = reg.toDescriptor();
        peer.nodeId = descriptor.id;
        registry.register(descriptor: descriptor, peer: peer, now: clock.now());
        audit.record(
          'node.register',
          principal: peer.principal?.id.value,
          detail: {'nodeId': descriptor.id.value},
        );
        peer.connection.send(
          ControlFrame(
            NodeRegistered(
              nodeId: descriptor.id.value,
              assignedAt: clock.now(),
            ),
          ),
        );
      case final NodeCapabilitiesMessage caps:
        final id = peer.nodeId;
        if (id != null) registry.updateCapabilities(id, caps.capabilities);
      case final NodeHeartbeat hb:
        final id = peer.nodeId;
        if (id != null) {
          final node = registry.byId(id);
          if (node != null && hb.seq > node.lastHeartbeatSeq) {
            registry.recordHeartbeat(
              id: id,
              seq: hb.seq,
              activeSessions: hb.activeSessions,
              now: clock.now(),
            );
          }
          peer.connection.send(
            ControlFrame(NodeHeartbeatAck(seq: hb.seq, ts: clock.now())),
          );
        }
      case final NodeSessionOpened opened:
        _handleNodeSessionOpened(peer, opened);
      case final NodeSessionRejected rejected:
        _handleNodeSessionRejected(peer, rejected);
      case final ChannelExit exit:
        _relayNodeToClient(peer, exit.channel, exit);
      case final ChannelWindow window:
        _relayNodeToClient(peer, window.channel, window);
      case final ChannelClose close:
        _handleChannelClose(peer, close);
      default:
        // Ignore unexpected control from a node.
        break;
    }
  }

  void _handleNodeSessionOpened(HubPeer peer, NodeSessionOpened opened) {
    final route = router.byNode(peer.id, opened.channel);
    if (route == null) return;
    route.state = SessionState.open;
    route.client.connection.send(
      ControlFrame(
        SessionOpened(
          channel: route.clientChannel,
          sessionId: route.sessionId.value,
          pty: route.mode == SessionMode.shell,
        ),
      ),
    );
  }

  void _handleNodeSessionRejected(HubPeer peer, NodeSessionRejected rejected) {
    final route = router.byNode(peer.id, rejected.channel);
    if (route == null) return;
    route.client.connection.send(
      ControlFrame(
        SessionRejected(
          channel: route.clientChannel,
          reason: rejected.reason,
          message: rejected.message,
        ),
      ),
    );
    _teardown(route, audit: false);
  }

  // --- Client-role handling -------------------------------------------------

  Future<void> _onClientControl(HubPeer peer, ControlMessage message) async {
    switch (message) {
      case final NodeListRequest req:
        peer.connection.send(
          ControlFrame(NodeListResponse(registry.list(filter: req.filter))),
        );
      case final SessionOpen open:
        await _handleSessionOpen(peer, open);
      case final ChannelResize resize:
        _relayClientToNode(peer, resize.channel, resize);
      case final ChannelSignal signal:
        _relayClientToNode(peer, signal.channel, signal);
      case final ChannelEof eof:
        _relayClientToNode(peer, eof.channel, eof);
      case final ChannelWindow window:
        _relayClientToNode(peer, window.channel, window);
      case final ChannelClose close:
        _handleChannelClose(peer, close);
      default:
        break;
    }
  }

  Future<void> _handleSessionOpen(HubPeer peer, SessionOpen open) async {
    final principal = peer.principal!;
    NodeId nodeId;
    try {
      nodeId = NodeId(open.nodeId);
    } on OmnyShellException {
      _rejectSession(
        peer,
        open.channel,
        ErrorCodes.badRequest,
        'Invalid node id',
      );
      return;
    }

    final node = registry.byId(nodeId);
    if (node == null) {
      _rejectSession(
        peer,
        open.channel,
        ErrorCodes.unknownNode,
        'No such node: ${open.nodeId}',
      );
      return;
    }
    if (!node.descriptor.online) {
      _rejectSession(
        peer,
        open.channel,
        ErrorCodes.nodeOffline,
        'Node offline',
      );
      return;
    }

    final allowed = await authorizer.canOpenSession(
      principal: principal,
      node: node.descriptor,
      mode: open.mode,
    );
    if (!allowed) {
      audit.record(
        'session.rejected',
        principal: principal.id.value,
        detail: {'nodeId': nodeId.value, 'reason': ErrorCodes.notAuthorized},
      );
      _rejectSession(
        peer,
        open.channel,
        ErrorCodes.notAuthorized,
        'Not authorized for node ${nodeId.value}',
      );
      return;
    }

    final maxSessions = node.descriptor.capabilities?.maxSessions ?? 1 << 30;
    if (node.activeSessions >= maxSessions) {
      _rejectSession(
        peer,
        open.channel,
        ErrorCodes.capacityExceeded,
        'Node at session capacity',
      );
      return;
    }

    final sessionId = SessionId.generate();
    final nodeChannel = node.peer.allocateChannel();
    final route = SessionRoute(
      sessionId: sessionId,
      nodeId: nodeId,
      principal: principal,
      mode: open.mode,
      client: peer,
      clientChannel: open.channel,
      node: node.peer,
      nodeChannel: nodeChannel,
      perSessionToken: newSecureToken(),
    );
    router.add(route);
    node.activeSessions++;
    audit.record(
      'session.open',
      principal: principal.id.value,
      detail: {
        'sessionId': sessionId.value,
        'nodeId': nodeId.value,
        'mode': open.mode.name,
      },
    );

    node.peer.connection.send(
      ControlFrame(
        NodeSessionOpen(
          channel: nodeChannel,
          sessionId: sessionId.value,
          principal: principal.id.value,
          mode: open.mode,
          command: open.command,
          args: open.args,
          env: open.env,
          cwd: open.cwd,
          pty: open.pty,
        ),
      ),
    );
  }

  // --- Relay helpers --------------------------------------------------------

  void _relayClientToNode(HubPeer peer, int channel, ControlMessage message) {
    final route = router.byClient(peer.id, channel);
    if (route == null) return;
    route.node.connection.send(
      ControlFrame(_reChannelControl(message, route.nodeChannel)),
    );
  }

  void _relayNodeToClient(HubPeer peer, int channel, ControlMessage message) {
    final route = router.byNode(peer.id, channel);
    if (route == null) return;
    route.client.connection.send(
      ControlFrame(_reChannelControl(message, route.clientChannel)),
    );
  }

  void _handleChannelClose(HubPeer peer, ChannelClose close) {
    if (peer.role == PeerRole.client) {
      final route = router.byClient(peer.id, close.channel);
      if (route == null) return;
      route.node.connection.send(
        ControlFrame(_reChannelControl(close, route.nodeChannel)),
      );
      _teardown(route);
    } else {
      final route = router.byNode(peer.id, close.channel);
      if (route == null) return;
      route.client.connection.send(
        ControlFrame(_reChannelControl(close, route.clientChannel)),
      );
      _teardown(route);
    }
  }

  void _teardown(SessionRoute route, {bool audit = true}) {
    router.remove(route.sessionId);
    final node = registry.byId(route.nodeId);
    if (node != null && node.activeSessions > 0) node.activeSessions--;
    if (audit) {
      this.audit.record(
        'session.close',
        principal: route.principal.id.value,
        detail: {'sessionId': route.sessionId.value},
      );
    }
  }

  void _rejectSession(
    HubPeer peer,
    int channel,
    String reason,
    String message,
  ) {
    peer.connection.send(
      ControlFrame(
        SessionRejected(channel: channel, reason: reason, message: message),
      ),
    );
  }

  // --- Peer / node teardown -------------------------------------------------

  void _onPeerGone(HubPeer peer) {
    _peers.remove(peer.id);
    final affected = router.removeForPeer(peer.id);
    for (final route in affected) {
      if (route.client.id == peer.id) {
        // Client vanished: ask the node to close its side.
        route.node.connection.send(
          ControlFrame(
            ChannelClose(channel: route.nodeChannel, reason: 'client_closed'),
          ),
        );
      } else {
        // Node vanished: tell the client.
        route.client.connection.send(
          ControlFrame(
            ChannelClose(
              channel: route.clientChannel,
              reason: 'node_closed',
              message: 'Node disconnected',
            ),
          ),
        );
      }
    }
    final nodeId = peer.nodeId;
    if (nodeId != null) {
      registry.remove(nodeId);
      audit.record('node.offline', detail: {'nodeId': nodeId.value});
    }
  }

  void _onNodeTimeout(RegisteredNode node) {
    logger?.call('node ${node.id.value} timed out');
    final affected = router.removeForPeer(node.peer.id);
    for (final route in affected) {
      route.client.connection.send(
        ControlFrame(
          ChannelClose(
            channel: route.clientChannel,
            reason: 'node_closed',
            message: 'Node heartbeat timeout',
          ),
        ),
      );
    }
    registry.remove(node.id);
    audit.record('node.timeout', detail: {'nodeId': node.id.value});
    unawaited(node.peer.connection.close(4408, 'heartbeat timeout'));
  }

  // --- Small helpers --------------------------------------------------------

  void _fail(HubPeer peer, String code, String message) {
    peer.connection.send(
      ControlFrame(ProtocolError(code: code, message: message, fatal: true)),
    );
    unawaited(peer.connection.close(4400, code));
  }

  PeerRole _roleFrom(String role) => switch (role) {
    'node' => PeerRole.node,
    'client' => PeerRole.client,
    _ => PeerRole.unknown,
  };

  DataFrame _reChannelData(DataFrame frame, int channel) => DataFrame(
    opcode: frame.opcode,
    channel: channel,
    payload: frame.payload,
    version: frame.version,
  );

  ControlMessage _reChannelControl(ControlMessage message, int channel) =>
      switch (message) {
        final ChannelResize m => ChannelResize(
          channel: channel,
          cols: m.cols,
          rows: m.rows,
        ),
        final ChannelSignal m => ChannelSignal(
          channel: channel,
          signal: m.signal,
        ),
        final ChannelEof m => ChannelEof(channel: channel, stream: m.stream),
        final ChannelExit m => ChannelExit(
          channel: channel,
          exitCode: m.exitCode,
          signal: m.signal,
          ts: m.ts,
        ),
        final ChannelClose m => ChannelClose(
          channel: channel,
          reason: m.reason,
          message: m.message,
        ),
        final ChannelWindow m => ChannelWindow(
          channel: channel,
          stream: m.stream,
          credit: m.credit,
        ),
        _ => message,
      };
}
