import 'dart:async';
import 'dart:io';

import '../../domain/backend/shell_backend.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/backend/shell_session.dart';
import '../../domain/entities/node_capabilities.dart';
import '../../domain/entities/platform_info.dart';
import '../../domain/entities/session.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/omny_uid.dart';
import '../../infrastructure/auth/credential_provider.dart';
import '../../infrastructure/identity/machine_id.dart';
import '../../infrastructure/identity/uid_computer.dart';
import '../../infrastructure/identity/uid_store.dart';
import '../../infrastructure/transport/web_socket_connection.dart';
import '../../protocol/channel.dart';
import '../../protocol/channel_multiplexer.dart';
import '../../protocol/control_message.dart';
import '../../protocol/omnyshell_frame.dart';
import '../../version.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/utils/clock.dart';
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
  int _heartbeatSeq = 0;
  bool _stopped = false;
  OmnyUid? _uid;

  /// Creates a node runtime from [config].
  NodeRuntime(this.config);

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
    final ready = _ready = Completer<void>();
    unawaited(_open());
    return ready.future;
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
      final session = _NodeSession(channel: channel, shell: shell);
      _sessions[open.channel] = session;

      _connection?.send(
        ControlFrame(
          NodeSessionOpened(
            channel: open.channel,
            sessionId: open.sessionId,
            pid: shell.pid,
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
    final shell = session.shell;

    // Capture stream completion via onDone (set at subscribe time) rather than
    // asFuture(): the output streams may close before we await them, and a
    // done event that has already fired cannot be observed by a late asFuture.
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    session.subscriptions.add(channel.stdin.listen(shell.writeStdin));
    session.subscriptions.add(
      shell.stdout.listen(
        channel.sendStdout,
        onDone: () => _complete(stdoutDone),
      ),
    );
    session.subscriptions.add(
      shell.stderr.listen(
        channel.sendStderr,
        onDone: () => _complete(stderrDone),
      ),
    );
    session.subscriptions.add(
      channel.control.listen((m) => _onSessionControl(nodeChannel, session, m)),
    );

    unawaited(() async {
      final code = await shell.exitCode;
      // The client closed the session (process was killed): the killed-after
      // output is irrelevant and the channel is already being torn down.
      if (session.disposed) return;
      // Drain any output still buffered in the process pipes before signalling
      // exit, so fast commands never lose their final bytes to the teardown.
      await stdoutDone.future;
      await stderrDone.future;
      if (session.disposed) return;
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

  static void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
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
      case final ChannelClose _:
        unawaited(_closeSession(nodeChannel));
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

  // --- Lifecycle ------------------------------------------------------------

  void _onDisconnected() {
    if (_state == NodeState.stopped) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    for (final session in _sessions.values.toList()) {
      unawaited(session.dispose());
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
    for (final session in _sessions.values.toList()) {
      await session.dispose();
    }
    _sessions.clear();
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
  final ShellSession shell;
  final List<StreamSubscription> subscriptions = [];

  /// Whether [dispose] has run (guards the exit-drain race).
  bool disposed = false;

  _NodeSession({required this.channel, required this.shell});

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    subscriptions.clear();
    await shell.kill();
    await channel.close();
  }
}
