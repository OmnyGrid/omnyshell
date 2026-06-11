import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/backend/shell_backend.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/backend/shell_session.dart';
import '../../domain/entities/detached_session_info.dart';
import '../../domain/entities/node_capabilities.dart';
import '../../domain/entities/platform_info.dart';
import '../../domain/entities/session.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/omny_uid.dart';
import '../../infrastructure/auth/credential_provider.dart';
import '../../infrastructure/identity/machine_id.dart';
import '../../infrastructure/identity/uid_computer.dart';
import '../../infrastructure/backend/process_inspector.dart';
import '../../infrastructure/identity/uid_store.dart';
import '../../infrastructure/transport/web_socket_connection.dart';
import '../../protocol/channel.dart';
import '../../protocol/channel_multiplexer.dart';
import '../../protocol/control_message.dart';
import '../../protocol/omnyshell_frame.dart';
import '../../version.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/id_generator.dart';
import 'detached_session_registry.dart';
import 'file_transfer_service.dart';
import 'node_drive_service.dart';
import 'reconnect_policy.dart';

/// The lifecycle state of a [NodeRuntime].
enum NodeState {
  /// Not connected.
  disconnected,

  /// Dialing the Hub / completing the WebSocket upgrade.
  connecting,

  /// Authenticating with the Hub.
  authenticating,

  /// Registering and advertising capabilities.
  registering,

  /// Connected, registered and serving sessions.
  serving,

  /// Backing off before a reconnect attempt.
  backoff,

  /// Permanently stopped (bad credentials or an explicit shutdown).
  stopped,
}

/// Configuration for a [NodeRuntime].
class NodeConfig {
  /// The Hub WebSocket URL (`wss://host:port/...`).
  final Uri hubUri;

  /// This node's stable id.
  final NodeId nodeId;

  /// A human-friendly display name.
  final String displayName;

  /// Operator labels (drive discovery and authorization policy).
  final Map<String, String> labels;

  /// Advertised capabilities.
  final NodeCapabilities capabilities;

  /// How the node authenticates to the Hub.
  final CredentialProvider credentials;

  /// Starts sessions on behalf of authorized clients.
  final ShellBackend backend;

  /// TLS trust roots for verifying the Hub certificate. `null` uses the system
  /// trust store.
  final SecurityContext? securityContext;

  /// Optional TLS certificate override (pinning / self-signed test certs).
  /// `null` enforces standard verification.
  final bool Function(X509Certificate cert, String host, int port)?
  onBadCertificate;

  /// How often to send heartbeats.
  final Duration heartbeatInterval;

  /// WebSocket ping interval used to detect a silently-dropped Hub connection.
  /// If a ping goes unanswered within this interval the socket closes, which
  /// drives reconnection.
  final Duration pingInterval;

  /// The reconnect backoff policy.
  final ReconnectPolicy reconnectPolicy;

  /// The OmnyShell build version this node advertises about itself, reported in
  /// [PlatformInfo.agentVersion] and shown to clients (e.g. `Agent: …` in
  /// `:info`). Defaults to [omnyShellVersion]; SDK embedders may override it with
  /// their own agent string.
  final String agentVersion;

  /// Whether this node accepts OmnyDrive mount sessions ([SessionMode.drive]).
  final bool driveEnabled;

  /// Absolute path prefixes a mount may target. Empty allows any path (the
  /// operator is trusted, as with exec). A non-empty list rejects mounts whose
  /// resolved path is not under one of these roots.
  final List<String> driveRoots;

  /// Whether a client connection that drops (network loss, crash, terminal
  /// closed) automatically detaches its session — keeping the PTY, shell and
  /// child processes alive for a later resume — instead of terminating it.
  /// Reuses the same detach path as the `:detach` command. Default `true`.
  final bool autoDetachOnDisconnect;

  /// Expiry applied to sessions detached automatically on disconnect, or `null`
  /// to keep them indefinitely. (Explicit `:detach <timeout>` overrides this.)
  final Duration? autoDetachTimeout;

  /// How often the cleanup service scans for expired detached sessions.
  final Duration cleanupInterval;

  /// The clock (overridable in tests).
  final Clock clock;

  /// Optional diagnostic logger.
  final void Function(String message)? logger;

  /// Creates a node configuration.
  NodeConfig({
    required this.hubUri,
    required this.nodeId,
    required this.credentials,
    required this.backend,
    NodeCapabilities? capabilities,
    this.displayName = '',
    this.labels = const {},
    this.securityContext,
    this.onBadCertificate,
    this.heartbeatInterval = const Duration(seconds: 10),
    this.pingInterval = const Duration(seconds: 20),
    ReconnectPolicy? reconnectPolicy,
    this.agentVersion = omnyShellVersion,
    this.driveEnabled = true,
    this.driveRoots = const [],
    this.autoDetachOnDisconnect = true,
    this.autoDetachTimeout,
    this.cleanupInterval = const Duration(minutes: 1),
    this.clock = const SystemClock(),
    this.logger,
  }) : capabilities = capabilities ?? NodeCapabilities.defaults(),
       reconnectPolicy = reconnectPolicy ?? ReconnectPolicy();
}

/// An embeddable OmnyShell node: maintains a secure connection to the Hub,
/// registers, advertises capabilities, and serves sessions, reconnecting with
/// backoff if the connection drops.
class NodeRuntime {
  /// The node configuration.
  final NodeConfig config;

  NodeState _state = NodeState.disconnected;
  WebSocketConnection? _connection;
  ChannelMultiplexer? _mux;
  StreamSubscription? _controlSub;
  Timer? _heartbeatTimer;
  Completer<void>? _ready;
  final Map<int, _NodeSession> _sessions = {};
  late final DetachedSessionRegistry _detached;
  Timer? _cleanupTimer;
  int _heartbeatSeq = 0;
  bool _stopped = false;
  OmnyUid? _uid;

  /// Creates a node runtime from [config].
  NodeRuntime(this.config) {
    _detached = DetachedSessionRegistry(clock: config.clock);
  }

  /// The current lifecycle state.
  NodeState get state => _state;

  /// This node's deterministic global UID, available once [connect] has begun.
  OmnyUid? get uid => _uid;

  /// The number of sessions currently being served.
  int get activeSessions => _sessions.length;

  /// Connects to the Hub, authenticates and registers.
  ///
  /// Completes once the node is registered and serving. Throws if
  /// authentication fails (a fatal, non-retryable error). Transient transport
  /// failures after a successful start trigger automatic reconnection rather
  /// than throwing.
  Future<void> connect() {
    _stopped = false;
    _startCleanup();
    final ready = _ready = Completer<void>();
    unawaited(_open());
    return ready.future;
  }

  /// The number of detached sessions held in this node's memory.
  int get detachedSessions => _detached.length;

  void _startCleanup() {
    _cleanupTimer ??= Timer.periodic(config.cleanupInterval, (_) {
      unawaited(_detached.killExpired(config.clock.now()));
    });
  }

  /// Computes and persists this node's UID once, warning if it changed since the
  /// last run. Best-effort: a failure leaves [_uid] null and registration omits
  /// it rather than blocking the connection.
  Future<void> _ensureUid() async {
    if (_uid != null) return;
    try {
      final publicKey = await config.credentials.identityPublicKeyBytes();
      final platform = PlatformInfo.local(agentVersion: config.agentVersion);
      final computed = UidComputer.computeNodeUid(
        publicKey: publicKey,
        machineId: MachineId.read(),
        os: platform.os,
        arch: platform.arch,
        hostname: platform.hostname,
      );
      final resolution = await const UidStore(
        fileName: 'node.uid',
      ).resolve(computed, logger: _log);
      _uid = resolution.uid;
    } on Object catch (e) {
      _log('UID computation failed: $e');
    }
  }

  Future<void> _open() async {
    if (_stopped) return;
    await _ensureUid();
    _setState(NodeState.connecting);
    final WebSocketConnection connection;
    try {
      connection = await WebSocketConnection.connect(
        config.hubUri,
        securityContext: config.securityContext,
        onBadCertificate: config.onBadCertificate,
        pingInterval: config.pingInterval,
      );
    } on Object catch (e) {
      _log('connect failed: $e');
      _scheduleReconnect();
      return;
    }

    _connection = connection;
    final mux = _mux = ChannelMultiplexer(connection);
    _setState(NodeState.authenticating);
    _controlSub = mux.control.listen(
      _onControl,
      onDone: _onDisconnected,
      cancelOnError: false,
    );
    unawaited(connection.done.then((_) => _onDisconnected()));
  }

  Future<void> _onControl(ControlMessage message) async {
    switch (message) {
      case final Hello hello:
        await _onHello(hello);
      case final AuthOk _:
        _setState(NodeState.registering);
        _sendRegistration();
      case final AuthFail fail:
        _log('authentication failed: ${fail.message}');
        _fatal();
      case final NodeRegistered _:
        _onRegistered();
      case final NodeSessionOpen open:
        await _onSessionOpen(open);
      case final NodeDetachedSessionsRequest req:
        await _onListDetached(req);
      case final NodeDetachedSessionKillRequest req:
        await _onKillSession(req);
      case final NodeSessionScreenRequest req:
        _onScreenRequest(req);
      case final NodeActiveSessionDetach req:
        await _onDetachActive(req);
      case final Ping ping:
        _connection?.send(
          ControlFrame(
            Pong(id: ping.id, ts: ping.ts, serverTs: config.clock.now()),
          ),
        );
      default:
        break;
    }
  }

  Future<void> _onHello(Hello hello) async {
    final nonce = hello.nonce ?? '';
    _connection?.send(
      ControlFrame(
        Hello(
          role: 'node',
          protocolVersion: kProtocolVersion,
          minVersion: kMinProtocolVersion,
          info: {'agent': 'omnyshell-node', 'version': config.agentVersion},
        ),
      ),
    );
    final auth = await config.credentials.createAuthRequest(nonce);
    _connection?.send(ControlFrame(auth));
  }

  void _sendRegistration() {
    final platform = PlatformInfo.local(agentVersion: config.agentVersion);
    _connection?.send(
      ControlFrame(
        NodeRegister(
          nodeId: config.nodeId.value,
          uid: _uid?.value,
          displayName: config.displayName.isEmpty
              ? config.nodeId.value
              : config.displayName,
          platform: platform,
          labels: config.labels,
        ),
      ),
    );
    _connection?.send(
      ControlFrame(NodeCapabilitiesMessage(config.capabilities)),
    );
  }

  void _onRegistered() {
    _setState(NodeState.serving);
    config.reconnectPolicy.reset();
    _startHeartbeat();
    if (_ready != null && !_ready!.isCompleted) _ready!.complete();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(config.heartbeatInterval, (_) {
      _connection?.send(
        ControlFrame(
          NodeHeartbeat(
            nodeId: config.nodeId.value,
            activeSessions: _sessions.length,
            seq: ++_heartbeatSeq,
            ts: config.clock.now(),
          ),
        ),
      );
    });
  }

  // --- Session serving ------------------------------------------------------

  Future<void> _onSessionOpen(NodeSessionOpen open) async {
    final mux = _mux;
    if (mux == null) return;
    final channel = mux.adopt(open.channel);

    // Transfer sessions are not backed by a process: a dedicated service drives
    // the framed, compressed file payload over the channel.
    if (open.mode == SessionMode.transfer) {
      _connection?.send(
        ControlFrame(
          NodeSessionOpened(channel: open.channel, sessionId: open.sessionId),
        ),
      );
      unawaited(
        FileTransferService(
          channel: channel,
          request: open,
          clock: config.clock,
          log: config.logger,
          onClose: () => mux.closeChannel(open.channel),
        ).run(),
      );
      return;
    }

    // Drive sessions serve an OmnyDrive mount: a long-lived request/response
    // channel handled by a dedicated service, not a process.
    if (open.mode == SessionMode.drive) {
      final reason = _rejectDriveReason(open);
      if (reason != null) {
        _connection?.send(
          ControlFrame(
            NodeSessionRejected(
              channel: open.channel,
              sessionId: open.sessionId,
              reason: 'forbidden',
              message: reason,
            ),
          ),
        );
        await mux.closeChannel(open.channel);
        return;
      }
      _connection?.send(
        ControlFrame(
          NodeSessionOpened(channel: open.channel, sessionId: open.sessionId),
        ),
      );
      unawaited(
        NodeDriveService(
          channel: channel,
          request: open,
          endpointId: _driveEndpointId(),
          clock: config.clock,
          log: config.logger,
          onClose: () => mux.closeChannel(open.channel),
        ).run(),
      );
      return;
    }

    // Resume: re-attach a previously detached session instead of starting a
    // fresh shell. Ownership is enforced by scoping the lookup to the caller.
    if (open.resumeSessionId != null) {
      await _resumeSession(open, channel);
      return;
    }

    try {
      final shell = await config.backend.start(
        ShellRequest(
          mode: open.mode,
          command: open.command,
          args: open.args,
          env: open.env,
          cwd: open.cwd,
          pty: open.pty,
        ),
      );
      final session = _NodeSession(
        channel: channel,
        pump: ShellOutputPump(shell),
        principal: open.principal,
        sessionId: open.sessionId,
        mode: open.mode,
        openedAt: config.clock.now(),
      );
      _sessions[open.channel] = session;

      _connection?.send(
        ControlFrame(
          NodeSessionOpened(
            channel: open.channel,
            sessionId: open.sessionId,
            pid: shell.pid,
            shell: shell.shellFamily.wireName,
          ),
        ),
      );
      _wireSession(open.channel, session);
    } on Object catch (e) {
      _connection?.send(
        ControlFrame(
          NodeSessionRejected(
            channel: open.channel,
            sessionId: open.sessionId,
            reason: 'bad_request',
            message: 'Failed to start session: $e',
          ),
        ),
      );
      await mux.closeChannel(open.channel);
    }
  }

  /// Returns a rejection reason for a drive session, or `null` to allow it.
  String? _rejectDriveReason(NodeSessionOpen open) {
    if (!config.driveEnabled) return 'drive mounts are disabled on this node';
    final path = open.command;
    if (path == null || path.isEmpty) return 'drive mount path is required';
    if (config.driveRoots.isEmpty) return null;
    final normalized = Uri.file(path).normalizePath().toFilePath();
    final allowed = config.driveRoots.any((root) {
      final r = Uri.file(root).normalizePath().toFilePath();
      return normalized == r ||
          normalized.startsWith('$r${Platform.pathSeparator}');
    });
    return allowed
        ? null
        : 'drive mount path "$path" is not within an allowed root';
  }

  /// A slug-form endpoint id for git drive scoping, derived from the node id.
  String _driveEndpointId() {
    final raw = config.nodeId.value.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_-]+'),
      '-',
    );
    final trimmed = raw.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'node' : trimmed;
  }

  void _wireSession(int nodeChannel, _NodeSession session) {
    final channel = session.channel;
    final pump = session.pump;

    // Point the (single, persistent) output pump at this channel. Stdin and
    // control are channel-bound and live in [subscriptions], so they are
    // cancelled on detach; the pump is not — its sinks are repointed instead.
    pump.onStdout = channel.sendStdout;
    pump.onStderr = channel.sendStderr;
    session.subscriptions.add(
      channel.stdin.listen((data) {
        pump.shell.writeStdin(data);
        // Replenish the client's stdin send window so a large paste into a
        // full-screen program can't drain the 256 KiB credit and stall input.
        if (data.isNotEmpty) {
          channel.sendControl(
            ChannelWindow(
              channel: nodeChannel,
              stream: 'stdin',
              credit: data.length,
            ),
          );
        }
      }),
    );
    session.subscriptions.add(
      channel.control.listen((m) => _onSessionControl(nodeChannel, session, m)),
    );

    unawaited(() async {
      final code = await pump.shell.exitCode;
      // The client closed the session (process was killed) or the session was
      // detached (a fresh watcher now owns the shell): in both cases this
      // channel is gone, so emit nothing on it.
      if (session.disposed || session.detached) return;
      // Drain any output still buffered in the process pipes before signalling
      // exit, so fast commands never lose their final bytes to the teardown.
      await pump.stdoutDone.future;
      await pump.stderrDone.future;
      if (session.disposed || session.detached) return;
      channel.sendControl(
        ChannelExit(
          channel: nodeChannel,
          exitCode: code,
          ts: config.clock.now(),
        ),
      );
      channel.sendControl(ChannelClose(channel: nodeChannel, reason: 'normal'));
      await _closeSession(nodeChannel);
    }());
  }

  void _onSessionControl(
    int nodeChannel,
    _NodeSession session,
    ControlMessage message,
  ) {
    switch (message) {
      case final ChannelResize resize:
        session.shell.resize(cols: resize.cols, rows: resize.rows);
      case final ChannelSignal signal:
        session.shell.sendSignal(signal.signal);
      case final ChannelEof _:
        unawaited(session.shell.closeStdin());
      case final NodeSessionDetach detach:
        unawaited(
          _detachSession(
            nodeChannel,
            timeout: detach.timeoutSeconds == null
                ? null
                : Duration(seconds: detach.timeoutSeconds!),
          ),
        );
      case final ChannelClose close:
        // An involuntary client disconnect detaches (preserving the shell) when
        // auto-detach is enabled; a deliberate `:exit` (`client_closed`) and any
        // other reason terminate the session as before.
        if (config.autoDetachOnDisconnect &&
            close.reason == 'client_disconnected') {
          unawaited(
            _detachSession(nodeChannel, timeout: config.autoDetachTimeout),
          );
        } else {
          unawaited(_closeSession(nodeChannel));
        }
      default:
        break;
    }
  }

  Future<void> _closeSession(int nodeChannel) async {
    final session = _sessions.remove(nodeChannel);
    if (session == null) return;
    await session.dispose();
    await _mux?.closeChannel(nodeChannel);
  }

  // --- Detachable sessions --------------------------------------------------

  /// Detaches the live session on [nodeChannel], moving it to the in-memory
  /// detached registry with the PTY/shell/processes left running. This is the
  /// single detach implementation shared by the `:detach` command, auto-detach
  /// on disconnect, and hub-connection loss.
  Future<void> _detachSession(int nodeChannel, {Duration? timeout}) async {
    final session = _sessions.remove(nodeChannel);
    if (session == null) return;
    final detached = await _parkSession(session, timeout: timeout);
    _connection?.send(
      ControlFrame(
        NodeSessionDetached(
          channel: nodeChannel,
          sessionId: detached.sessionId,
          shortId: detached.shortId,
          expiresAt: detached.expiresAt,
        ),
      ),
    );
    await _mux?.closeChannel(nodeChannel);
  }

  /// Cancels the channel-bound wiring of [session] (without killing the shell),
  /// drops the live output sink (the pump keeps capturing into its screen
  /// buffer), builds a [DetachedNodeSession] and adds it to the registry.
  /// Returns the parked session.
  Future<DetachedNodeSession> _parkSession(
    _NodeSession session, {
    Duration? timeout,
  }) async {
    // Drop the live sink; the pump's always-on screen capture keeps running, so
    // output produced while detached (and the pre-detach frame) is retained for
    // the resume repaint.
    session.pump.onStdout = null;
    session.pump.onStderr = null;
    await session.detachKeepingShell();
    final now = config.clock.now();
    final sid = session.sessionId;
    final detached = DetachedNodeSession(
      sessionId: sid,
      shortId: shortId(sid),
      ownerPrincipal: session.principal,
      nodeId: config.nodeId,
      mode: session.mode,
      createdAt: session.openedAt,
      detachedAt: now,
      expiresAt: timeout == null ? null : now.add(timeout),
      pump: session.pump,
    );
    _detached.add(detached);
    _log('session ${detached.shortId} detached (owner ${session.principal})');
    return detached;
  }

  /// Resumes a detached session named by [open.resumeSessionId], binding its
  /// still-running shell to the freshly adopted [channel].
  Future<void> _resumeSession(NodeSessionOpen open, Channel channel) async {
    final result = _detached.resolveRef(open.principal, open.resumeSessionId!);
    if (result.status != SessionRefStatus.found) {
      // notFound covers both "no such session" and another user's session
      // (the lookup is owner-scoped), so existence is never leaked.
      final (reason, message) = switch (result.status) {
        SessionRefStatus.ambiguous => (
          'ambiguous',
          'Ambiguous session id; use more characters',
        ),
        _ => ('not_found', 'No such detached session'),
      };
      _connection?.send(
        ControlFrame(
          NodeSessionRejected(
            channel: open.channel,
            sessionId: open.sessionId,
            reason: reason,
            message: message,
          ),
        ),
      );
      await _mux?.closeChannel(open.channel);
      return;
    }

    final entry = result.session!;
    _detached.removeById(entry.sessionId);

    final session = _NodeSession(
      channel: channel,
      pump: entry.pump,
      principal: entry.ownerPrincipal,
      sessionId: entry.sessionId,
      mode: entry.mode,
      openedAt: entry.createdAt,
    );
    _sessions[open.channel] = session;

    // Report whether the resume lands inside a full-screen program so the
    // client suppresses prompt-priming and goes straight to passthrough.
    final altScreen = entry.pump.screen.inAltScreen;
    _connection?.send(
      ControlFrame(
        NodeSessionOpened(
          channel: open.channel,
          sessionId: entry.sessionId,
          pid: entry.shell.pid,
          altScreen: altScreen,
          shell: entry.shell.shellFamily.wireName,
        ),
      ),
    );
    // Repaint the current screen (for a full-screen program, everything since
    // it entered the alt screen; otherwise the scrollback tail), then bind live
    // output to the new channel. This whole block runs in one synchronous turn
    // so no output is interleaved or lost, and `_wireSession` repoints the pump
    // sinks to the channel.
    final replay = entry.pump.screen.replaySnapshot();
    if (replay.isNotEmpty) channel.sendStdout(replay);
    _wireSession(open.channel, session);
    _log(
      'session ${entry.shortId} resumed '
      '(owner ${entry.ownerPrincipal}, altScreen: $altScreen)',
    );
  }

  Future<void> _onListDetached(NodeDetachedSessionsRequest req) async {
    // Active (attached) shell sessions the caller owns, so another window can
    // discover the running session it wants to detach...
    final active = _sessions.values
        .where(
          (s) =>
              s.mode == SessionMode.shell &&
              s.principal == req.principal &&
              !s.detached,
        )
        .map((s) => (info: _activeInfo(s), pid: s.shell.pid));
    // ...alongside the parked (detached) ones.
    final detached = _detached
        .listForOwner(req.principal)
        .map((s) => (info: s.toInfo(), pid: s.shell.pid));
    // Augment each session with its live foreground command and cwd, queried
    // from the OS by shell pid (best-effort; null on unsupported platforms).
    final sessions = await Future.wait([
      for (final e in [...active, ...detached])
        () async {
          if (e.pid == null) return e.info;
          final snap = await inspectProcess(e.pid!);
          return e.info.withLiveState(command: snap.command, cwd: snap.cwd);
        }(),
    ]);
    _connection?.send(
      ControlFrame(
        NodeDetachedSessionsResponse(
          requestId: req.requestId,
          sessions: sessions,
        ),
      ),
    );
  }

  DetachedSessionInfo _activeInfo(_NodeSession s) => DetachedSessionInfo(
    sessionId: s.sessionId,
    shortId: shortId(s.sessionId),
    nodeId: config.nodeId.value,
    ownerUserId: s.principal,
    mode: s.mode,
    createdAt: s.openedAt,
    state: SessionState.attached,
  );

  /// Terminates one of the caller's sessions — *running* (attached) or detached
  /// — named by [req.sessionRef]. Active and detached candidates are resolved
  /// together so an ambiguous prefix across both is rejected.
  Future<void> _onKillSession(NodeDetachedSessionKillRequest req) async {
    // Active (attached) shell sessions owned by the caller that match the ref.
    final activeMatches = _sessions.entries
        .where(
          (e) =>
              e.value.mode == SessionMode.shell &&
              e.value.principal == req.principal &&
              !e.value.detached &&
              _refMatches(e.value.sessionId, req.sessionRef),
        )
        .toList();
    final detachedResult = _detached.resolveRef(req.principal, req.sessionRef);
    final detachedHit = detachedResult.status == SessionRefStatus.found
        ? detachedResult.session
        : null;
    final totalMatches = activeMatches.length + (detachedHit != null ? 1 : 0);

    bool ok = false;
    String message;
    if (detachedResult.status == SessionRefStatus.ambiguous ||
        activeMatches.length > 1 ||
        totalMatches > 1) {
      message = 'Ambiguous session id; use more characters';
    } else if (totalMatches == 0) {
      message = 'No such session';
    } else if (activeMatches.length == 1) {
      final entry = activeMatches.single;
      final handle = shortId(entry.value.sessionId);
      await _killActiveSession(entry.key);
      ok = true;
      message = 'Session $handle terminated';
    } else {
      final entry = detachedHit!;
      _detached.removeById(entry.sessionId);
      await entry.kill();
      ok = true;
      message = 'Session ${entry.shortId} terminated';
    }
    _connection?.send(
      ControlFrame(
        NodeDetachedSessionKillResponse(
          requestId: req.requestId,
          ok: ok,
          message: message,
        ),
      ),
    );
  }

  /// Returns the current screen snapshot of one of the caller's sessions —
  /// *running* (attached) or detached — named by [req.sessionRef], without
  /// disturbing it. The replayed bytes are exactly what a resume would paint.
  void _onScreenRequest(NodeSessionScreenRequest req) {
    // Active (attached) shell sessions owned by the caller that match the ref.
    final activeMatches = _sessions.values
        .where(
          (s) =>
              s.mode == SessionMode.shell &&
              s.principal == req.principal &&
              !s.detached &&
              _refMatches(s.sessionId, req.sessionRef),
        )
        .toList();
    final detachedResult = _detached.resolveRef(req.principal, req.sessionRef);
    final detachedHit = detachedResult.status == SessionRefStatus.found
        ? detachedResult.session
        : null;
    final totalMatches = activeMatches.length + (detachedHit != null ? 1 : 0);

    bool ok = false;
    String message = '';
    String screenBase64 = '';
    bool altScreen = false;
    if (detachedResult.status == SessionRefStatus.ambiguous ||
        activeMatches.length > 1 ||
        totalMatches > 1) {
      message = 'Ambiguous session id; use more characters';
    } else if (totalMatches == 0) {
      message = 'No such session';
    } else {
      final pump = activeMatches.length == 1
          ? activeMatches.single.pump
          : detachedHit!.pump;
      ok = true;
      screenBase64 = base64.encode(pump.screen.replaySnapshot());
      altScreen = pump.screen.inAltScreen;
    }
    _connection?.send(
      ControlFrame(
        NodeSessionScreenResponse(
          requestId: req.requestId,
          ok: ok,
          message: message,
          screenBase64: screenBase64,
          altScreen: altScreen,
        ),
      ),
    );
  }

  /// Terminates the active session on [nodeChannel], notifying its attached
  /// client (so its prompt/full-screen program tears down) before killing the
  /// shell. Without the explicit close the client would never learn the session
  /// ended, since the killed-after exit drain is suppressed.
  Future<void> _killActiveSession(int nodeChannel) async {
    final session = _sessions[nodeChannel];
    session?.channel.sendControl(
      ChannelClose(
        channel: nodeChannel,
        reason: 'node_closed',
        message: 'Session terminated',
      ),
    );
    await _closeSession(nodeChannel);
  }

  /// Detaches an *active* session on behalf of [req.principal] (triggered from a
  /// separate connection — e.g. to escape a full-screen program). Funnels into
  /// the same [_detachSession] path, which also notifies the attached client.
  Future<void> _onDetachActive(NodeActiveSessionDetach req) async {
    final owned = _sessions.entries
        .where(
          (e) =>
              e.value.mode == SessionMode.shell &&
              e.value.principal == req.principal &&
              !e.value.detached,
        )
        .toList();
    // Empty ref ⇒ the sole active session; otherwise prefix-match the id.
    final matches = req.sessionRef.isEmpty
        ? owned
        : owned
              .where((e) => _refMatches(e.value.sessionId, req.sessionRef))
              .toList();

    bool ok = false;
    String shortHandle = '';
    String message;
    if (matches.isEmpty) {
      message = req.sessionRef.isEmpty
          ? 'No active session to detach'
          : 'No such active session';
    } else if (matches.length > 1) {
      message = req.sessionRef.isEmpty
          ? 'Multiple active sessions; specify a session id'
          : 'Ambiguous session id; use more characters';
    } else {
      final entry = matches.single;
      shortHandle = shortId(entry.value.sessionId);
      await _detachSession(
        entry.key,
        timeout: req.timeoutSeconds == null
            ? null
            : Duration(seconds: req.timeoutSeconds!),
      );
      ok = true;
      message = 'Session $shortHandle detached';
    }
    _connection?.send(
      ControlFrame(
        NodeActiveSessionDetachResponse(
          requestId: req.requestId,
          ok: ok,
          shortId: shortHandle,
          message: message,
        ),
      ),
    );
  }

  /// Whether [ref] (an id, short id or prefix, hyphens ignored) names [sessionId].
  static bool _refMatches(String sessionId, String ref) {
    final r = ref.replaceAll('-', '').toLowerCase();
    return r.isNotEmpty &&
        sessionId.replaceAll('-', '').toLowerCase().startsWith(r);
  }

  // --- Lifecycle ------------------------------------------------------------

  void _onDisconnected() {
    if (_state == NodeState.stopped) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // Losing the Hub disconnects every client; with auto-detach the shells are
    // preserved (parked in the registry) so they survive a Hub blip and stay
    // resumable after reconnect, rather than being killed.
    for (final session in _sessions.values.toList()) {
      if (config.autoDetachOnDisconnect) {
        unawaited(_parkSession(session, timeout: config.autoDetachTimeout));
      } else {
        unawaited(session.dispose());
      }
    }
    _sessions.clear();
    _controlSub?.cancel();
    _controlSub = null;
    _connection = null;
    _mux = null;
    if (_stopped) {
      _setState(NodeState.stopped);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _setState(NodeState.backoff);
    final delay = config.reconnectPolicy.nextDelay();
    _log('reconnecting in ${delay.inMilliseconds}ms');
    Timer(delay, () {
      if (!_stopped) unawaited(_open());
    });
  }

  void _fatal() {
    _stopped = true;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('Node authentication failed'));
    }
    unawaited(_connection?.close());
    _setState(NodeState.stopped);
  }

  /// Disconnects and stops the node. No further reconnection is attempted.
  Future<void> shutdown() async {
    _stopped = true;
    _heartbeatTimer?.cancel();
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    for (final session in _sessions.values.toList()) {
      await session.dispose();
    }
    _sessions.clear();
    await _detached.disposeAll();
    await _controlSub?.cancel();
    await _mux?.dispose();
    await _connection?.close();
    _connection = null;
    _mux = null;
    _setState(NodeState.stopped);
  }

  void _setState(NodeState state) {
    _state = state;
    _log('state -> ${state.name}');
  }

  void _log(String message) => config.logger?.call('[node] $message');
}

class _NodeSession {
  final Channel channel;

  /// The persistent pump over the shell's output (survives detach/resume).
  final ShellOutputPump pump;

  /// The authenticated principal that owns this session.
  final String principal;

  /// The hub-minted session id.
  final String sessionId;

  /// The session mode.
  final SessionMode mode;

  /// When the session was first opened (preserved across detach/resume).
  final DateTime openedAt;

  /// The channel-bound subscriptions (stdin, control) cancelled on detach.
  final List<StreamSubscription> subscriptions = [];

  /// Whether [dispose] has run (guards the exit-drain race).
  bool disposed = false;

  /// Whether the session was detached (the shell now belongs to the registry).
  bool detached = false;

  /// The still-running shell/PTY.
  ShellSession get shell => pump.shell;

  _NodeSession({
    required this.channel,
    required this.pump,
    required this.principal,
    required this.sessionId,
    required this.mode,
    required this.openedAt,
  });

  /// Tears the session down completely: cancels wiring, releases the pump,
  /// kills the shell/PTY, and closes the channel.
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    subscriptions.clear();
    await pump.dispose();
    await pump.shell.kill();
    await channel.close();
  }

  /// Cancels the channel-bound wiring and closes the channel, but leaves the
  /// shell/PTY and the output pump running for the detached registry to adopt.
  /// The caller repoints the pump's sinks before/after this in the same turn.
  Future<void> detachKeepingShell() async {
    if (detached || disposed) return;
    detached = true;
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    subscriptions.clear();
    await channel.close();
  }
}
