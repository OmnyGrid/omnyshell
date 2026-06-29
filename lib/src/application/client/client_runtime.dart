import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/auth/principal.dart';
import '../../domain/backend/pty_spec.dart';
import '../../domain/backend/shell_family.dart';
import '../../domain/entities/detached_session_info.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tunnel_info.dart';
import '../../domain/value_objects/principal_id.dart';
import '../../infrastructure/auth/credential_provider.dart';
import '../../infrastructure/transport/transport_factory.dart';
import '../../protocol/channel.dart';
import '../../protocol/channel_multiplexer.dart';
import '../../protocol/control_message.dart';
import '../../protocol/omnyshell_connection.dart';
import '../../protocol/omnyshell_frame.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/errors/omnyshell_exception.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/id_generator.dart';
import '../tunnel/local_tunnel_bridge_factory.dart';
import 'remote_session.dart';

/// The result of a one-shot [ClientRuntime.execute].
class ExecResult {
  /// The process exit code.
  final int exitCode;

  /// Captured standard output bytes.
  final Uint8List stdout;

  /// Captured standard error bytes.
  final Uint8List stderr;

  /// Creates an exec result.
  ExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// Standard output decoded as UTF-8.
  String get stdoutText => utf8.decode(stdout, allowMalformed: true);

  /// Standard error decoded as UTF-8.
  String get stderrText => utf8.decode(stderr, allowMalformed: true);
}

/// The result of [ClientRuntime.killDetachedSession].
class DetachedSessionKillResult {
  /// Whether the session was found, owned by the caller, and terminated.
  final bool ok;

  /// A human-readable result/error message.
  final String message;

  /// Creates a kill result.
  const DetachedSessionKillResult({required this.ok, required this.message});
}

/// A handle to an open tunnel returned by [ClientRuntime.openTunnel].
class TunnelHandle {
  /// The full tunnel id (use any unambiguous prefix to close it).
  final String tunnelId;

  /// The exposer node id, or `@local` when exposing the client's own machine.
  final String nodeId;

  /// The host the Hub advertises for the public port (may be empty when the
  /// caller should substitute the Hub's own hostname).
  final String publicHost;

  /// The public TCP port the Hub is listening on.
  final int publicPort;

  /// The internal target port being exposed.
  final int targetPort;

  /// Whether the public port terminates TLS (HTTPS).
  final bool secure;

  /// Creates a tunnel handle.
  const TunnelHandle({
    required this.tunnelId,
    required this.nodeId,
    required this.publicHost,
    required this.publicPort,
    required this.targetPort,
    this.secure = false,
  });

  /// A short, display-only handle derived from [tunnelId].
  String get shortId =>
      tunnelId.length <= 8 ? tunnelId : tunnelId.substring(0, 8);
}

/// The result of [ClientRuntime.closeTunnel].
class TunnelCloseResult {
  /// Whether a tunnel was found, owned by the caller, and closed.
  final bool ok;

  /// A human-readable result/error message.
  final String message;

  /// Creates a tunnel-close result.
  const TunnelCloseResult({required this.ok, required this.message});
}

/// The Hub's advertised default AI configuration, returned by
/// [ClientRuntime.fetchHubAiConfig]. Never carries an API key — the key stays on
/// the Hub. [available] is false when the Hub has no default provider.
class HubAiConfig {
  /// Whether the Hub has a usable default provider+key configured.
  final bool available;

  /// The default provider token (e.g. `anthropic`), or `null`.
  final String? provider;

  /// The default shared model id, or `null`.
  final String? model;

  /// Optional planner model override.
  final String? plannerModel;

  /// Optional executor model override.
  final String? executorModel;

  /// Optional explainer model override.
  final String? explainerModel;

  /// Optional API base-URL override.
  final String? baseUrl;

  /// The default agent mode token (e.g. `plan`), or `null`.
  final String? mode;

  /// The default reply language, or `null`.
  final String? language;

  /// Creates a Hub AI config snapshot.
  const HubAiConfig({
    required this.available,
    this.provider,
    this.model,
    this.plannerModel,
    this.executorModel,
    this.explainerModel,
    this.baseUrl,
    this.mode,
    this.language,
  });
}

/// The result of [ClientRuntime.peekSession]: the current screen snapshot of a
/// session, captured without attaching to it.
class SessionScreenResult {
  /// Whether a session was found, owned by the caller, and captured.
  final bool ok;

  /// A human-readable result/error message.
  final String message;

  /// The captured screen bytes — the same a resume would paint (empty on
  /// failure).
  final Uint8List screen;

  /// Whether the capture ends inside the alternate screen (full-screen program).
  final bool altScreen;

  /// Creates a peek result.
  const SessionScreenResult({
    required this.ok,
    required this.message,
    required this.screen,
    required this.altScreen,
  });
}

/// The result of [ClientRuntime.detachActiveSession].
class ActiveSessionDetachResult {
  /// Whether an owned active session was found and detached.
  final bool ok;

  /// The short handle of the detached session (empty on failure), used to
  /// resume it later.
  final String shortId;

  /// A human-readable result/error message.
  final String message;

  /// Creates an active-detach result.
  const ActiveSessionDetachResult({
    required this.ok,
    required this.shortId,
    required this.message,
  });
}

/// Configuration for a [ClientRuntime].
class ClientConfig {
  /// The Hub WebSocket URL (`wss://host:port/...`).
  final Uri hubUri;

  /// How the client authenticates to the Hub.
  final CredentialProvider credentials;

  /// Opens the transport to [hubUri]. When `null`, the platform default is
  /// used: a `dart:io` `wss://` socket on the VM, or the browser WebSocket on
  /// the web. Native callers that need TLS trust overrides (self-signed certs,
  /// pinning) pass `ioConnectionFactory(...)` from
  /// `infrastructure/transport/io_connection_factory.dart`.
  final ConnectionFactory? connectionFactory;

  /// The clock (overridable in tests).
  final Clock clock;

  /// Optional diagnostic logger.
  final void Function(String message)? logger;

  /// Called when the connection to the Hub drops (after pending operations are
  /// failed). Fires on both unexpected loss and an explicit [ClientRuntime.close];
  /// callers that need to distinguish should track their own intent.
  final void Function()? onDisconnected;

  /// Creates a client configuration.
  ClientConfig({
    required this.hubUri,
    required this.credentials,
    this.connectionFactory,
    this.clock = const SystemClock(),
    this.logger,
    this.onDisconnected,
  });
}

/// An embeddable OmnyShell client: authenticates with the Hub, discovers nodes,
/// and opens exec / interactive sessions.
///
/// ```dart
/// final client = OmnyShellClient(config);
/// await client.connect();
/// final result = await client.execute(nodeId: 'web-01', command: 'uname -a');
/// ```
class ClientRuntime {
  /// The client configuration.
  final ClientConfig config;

  OmnyShellConnection? _connection;
  ChannelMultiplexer? _mux;
  StreamSubscription? _controlSub;
  Principal? _principal;
  Completer<void>? _auth;

  final Queue<Completer<List<NodeDescriptor>>> _pendingNodeLists = Queue();
  final Map<String, Completer<Duration>> _pendingPings = {};
  final Map<String, Completer<List<DetachedSessionInfo>>> _pendingSessionLists =
      {};
  final Map<String, Completer<DetachedSessionKillResult>> _pendingSessionKills =
      {};
  final Map<String, Completer<ActiveSessionDetachResult>> _pendingActiveDetach =
      {};
  final Map<String, Completer<SessionScreenResult>> _pendingSessionScreens = {};
  final Map<
    String,
    ({Completer<TunnelHandle> completer, String nodeId, int targetPort})
  >
  _pendingTunnelOpens = {};
  final Map<String, Completer<List<TunnelInfo>>> _pendingTunnelLists = {};
  final Map<String, Completer<TunnelCloseResult>> _pendingTunnelCloses = {};
  final Map<String, Completer<HubAiConfig>> _pendingAiConfigs = {};
  final Map<String, Completer<HttpProxyResponse>> _pendingHttpProxies = {};

  /// Live tunnel bridges for `@local` tunnels exposing this client's machine,
  /// keyed by the Hub-allocated channel id.
  final Map<int, LocalTunnelBridge> _clientTunnels = {};

  /// Creates a client runtime from [config].
  ClientRuntime(this.config);

  /// The authenticated principal (available after [connect]).
  Principal? get principal => _principal;

  /// Whether the client is connected and authenticated.
  bool get isConnected => _principal != null && (_connection?.isOpen ?? false);

  /// Connects to the Hub and authenticates.
  ///
  /// Throws [AuthException] if authentication fails, or [TransportException] if
  /// the connection cannot be established.
  Future<void> connect() async {
    final auth = _auth = Completer<void>();
    final factory = config.connectionFactory ?? defaultConnectionFactory;
    final OmnyShellConnection connection;
    try {
      connection = await factory(config.hubUri);
    } on Object catch (e) {
      throw TransportException('Failed to connect to Hub: $e');
    }
    _connection = connection;
    final mux = _mux = ChannelMultiplexer(connection, firstChannelId: 1);
    _controlSub = mux.control.listen(
      _onControl,
      onDone: _onDisconnected,
      cancelOnError: false,
    );
    unawaited(connection.done.then((_) => _onDisconnected()));
    await auth.future;
  }

  Future<void> _onControl(ControlMessage message) async {
    switch (message) {
      case final Hello hello:
        await _onHello(hello);
      case final AuthOk ok:
        _principal = Principal(
          id: PrincipalId(ok.principal),
          displayName: ok.displayName,
          roles: ok.roles.toSet(),
        );
        if (_auth != null && !_auth!.isCompleted) _auth!.complete();
      case final AuthFail fail:
        if (_auth != null && !_auth!.isCompleted) {
          _auth!.completeError(AuthException(fail.message));
        }
      case final NodeListResponse response:
        if (_pendingNodeLists.isNotEmpty) {
          _pendingNodeLists.removeFirst().complete(response.nodes);
        }
      case final Pong pong:
        final completer = _pendingPings.remove(pong.id);
        completer?.complete(config.clock.now().difference(pong.ts));
      case final DetachedSessionsResponse resp:
        _pendingSessionLists.remove(resp.requestId)?.complete(resp.sessions);
      case final SessionScreenResponse resp:
        _pendingSessionScreens
            .remove(resp.requestId)
            ?.complete(
              SessionScreenResult(
                ok: resp.ok,
                message: resp.message,
                screen: resp.screenBase64.isEmpty
                    ? Uint8List(0)
                    : base64.decode(resp.screenBase64),
                altScreen: resp.altScreen,
              ),
            );
      case final DetachedSessionKillResponse resp:
        _pendingSessionKills
            .remove(resp.requestId)
            ?.complete(
              DetachedSessionKillResult(ok: resp.ok, message: resp.message),
            );
      case final ActiveSessionDetachResponse resp:
        _pendingActiveDetach
            .remove(resp.requestId)
            ?.complete(
              ActiveSessionDetachResult(
                ok: resp.ok,
                shortId: resp.shortId,
                message: resp.message,
              ),
            );
      case final TunnelOpened resp:
        final pending = _pendingTunnelOpens.remove(resp.requestId);
        pending?.completer.complete(
          TunnelHandle(
            tunnelId: resp.tunnelId,
            nodeId: pending.nodeId,
            publicHost: resp.publicHost,
            publicPort: resp.publicPort,
            targetPort: pending.targetPort,
            secure: resp.secure,
          ),
        );
      case final TunnelRejected resp:
        _pendingTunnelOpens
            .remove(resp.requestId)
            ?.completer
            .completeError(
              TunnelRejectedException(resp.message, code: resp.reason),
            );
      case final TunnelListResponse resp:
        _pendingTunnelLists.remove(resp.requestId)?.complete(resp.tunnels);
      case final TunnelCloseResponse resp:
        _pendingTunnelCloses
            .remove(resp.requestId)
            ?.complete(TunnelCloseResult(ok: resp.ok, message: resp.message));
      case final AiConfigResponse resp:
        _pendingAiConfigs
            .remove(resp.requestId)
            ?.complete(
              HubAiConfig(
                available: resp.available,
                provider: resp.provider,
                model: resp.model,
                plannerModel: resp.plannerModel,
                executorModel: resp.executorModel,
                explainerModel: resp.explainerModel,
                baseUrl: resp.baseUrl,
                mode: resp.mode,
                language: resp.language,
              ),
            );
      case final HttpProxyResponse resp:
        _pendingHttpProxies.remove(resp.requestId)?.complete(resp);
      case final NodeTunnelConnect connect:
        await _onTunnelConnect(connect);
      default:
        break;
    }
  }

  Future<void> _onHello(Hello hello) async {
    _connection?.send(
      ControlFrame(
        Hello(
          role: 'client',
          protocolVersion: kProtocolVersion,
          minVersion: kMinProtocolVersion,
          info: {'agent': 'omnyshell-client'},
        ),
      ),
    );
    final auth = await config.credentials.createAuthRequest(hello.nonce ?? '');
    _connection?.send(ControlFrame(auth));
  }

  /// Lists the nodes visible to this client, with an optional label [filter].
  Future<List<NodeDescriptor>> listNodes({
    Map<String, String> filter = const {},
  }) {
    _ensureConnected();
    final completer = Completer<List<NodeDescriptor>>();
    _pendingNodeLists.add(completer);
    _connection!.send(ControlFrame(NodeListRequest(filter: filter)));
    return completer.future;
  }

  /// Measures round-trip latency to the Hub.
  Future<Duration> ping() {
    _ensureConnected();
    final id = newId();
    final completer = Completer<Duration>();
    _pendingPings[id] = completer;
    _connection!.send(ControlFrame(Ping(id: id, ts: config.clock.now())));
    return completer.future;
  }

  /// Opens a session on [nodeId].
  ///
  /// Completes once the node confirms the session, or throws
  /// [SessionRejectedException] if it is refused.
  Future<RemoteSession> openSession({
    required String nodeId,
    SessionMode mode = SessionMode.exec,
    String? command,
    List<String> args = const [],
    Map<String, String> env = const {},
    String? cwd,
    PtySpec? pty,
    String? resumeSessionId,
    ShellFamily? shellFamily,
  }) async {
    _ensureConnected();
    final Channel channel = _mux!.open();
    final session = RemoteSession(channel, mode);
    _connection!.send(
      ControlFrame(
        SessionOpen(
          channel: channel.id,
          nodeId: nodeId,
          mode: mode,
          command: command,
          args: args,
          env: env,
          cwd: cwd,
          pty: pty,
          resumeSessionId: resumeSessionId,
          shellFamily: shellFamily,
        ),
      ),
    );
    try {
      await session.opened;
    } on Object {
      await _mux!.closeChannel(channel.id);
      rethrow;
    }
    return session;
  }

  /// Resumes a previously detached interactive session on [nodeId], identified
  /// by [sessionId] (a full id, short handle, or unambiguous prefix). The
  /// returned session continues exactly where it was detached; the node
  /// enforces that the caller owns it.
  Future<RemoteSession> resumeSession({
    required String nodeId,
    required String sessionId,
    PtySpec? pty,
  }) => openSession(
    nodeId: nodeId,
    mode: SessionMode.shell,
    pty: pty,
    resumeSessionId: sessionId,
  );

  /// Lists the caller's sessions on [nodeId] — both active (attached) and
  /// detached. The node filters by owner, so only the authenticated user's
  /// sessions are returned.
  Future<List<DetachedSessionInfo>> listSessions({required String nodeId}) {
    _ensureConnected();
    final id = newId();
    final completer = Completer<List<DetachedSessionInfo>>();
    _pendingSessionLists[id] = completer;
    _connection!.send(
      ControlFrame(DetachedSessionsRequest(requestId: id, nodeId: nodeId)),
    );
    return completer.future;
  }

  /// Lists only the caller's *detached* sessions on [nodeId].
  Future<List<DetachedSessionInfo>> listDetachedSessions({
    required String nodeId,
  }) async => (await listSessions(
    nodeId: nodeId,
  )).where((s) => s.state == SessionState.detached).toList();

  /// Fetches the Hub's default AI configuration (provider/model, never a key),
  /// so a browser embedder can offer "use the Hub default". Returns a
  /// [HubAiConfig] with `available == false` when the Hub has none configured.
  Future<HubAiConfig> fetchHubAiConfig() {
    _ensureConnected();
    final id = newId();
    final completer = Completer<HubAiConfig>();
    _pendingAiConfigs[id] = completer;
    _connection!.send(ControlFrame(AiConfigRequest(requestId: id)));
    return completer.future;
  }

  /// Asks the Hub to perform an outbound AI HTTPS request on the caller's behalf
  /// — used by the browser client, which cannot reach provider APIs directly
  /// (CORS). The Hub enforces an https + host allowlist and, when
  /// [credentialMode] is [HttpProxyCredentialMode.hubDefault], injects its own
  /// key for [provider]; otherwise [headers] (with the caller's key) are
  /// forwarded verbatim. Completes with the provider's reply, or an
  /// [HttpProxyResponse] whose `error` is set on a rejected target / transport
  /// failure.
  Future<HttpProxyResponse> proxyHttp({
    required String method,
    required String url,
    Map<String, String> headers = const {},
    String body = '',
    HttpProxyCredentialMode credentialMode = HttpProxyCredentialMode.none,
    String? provider,
  }) {
    _ensureConnected();
    final id = newId();
    final completer = Completer<HttpProxyResponse>();
    _pendingHttpProxies[id] = completer;
    _connection!.send(
      ControlFrame(
        HttpProxyRequest(
          requestId: id,
          method: method,
          url: url,
          headers: headers,
          body: body,
          credentialMode: credentialMode,
          provider: provider,
        ),
      ),
    );
    return completer.future;
  }

  /// Fetches the current screen snapshot of one of the caller's sessions on
  /// [nodeId] — **running** (attached) or detached — named by [sessionRef] (a
  /// full id, short handle, or unambiguous prefix), *without attaching to it*.
  /// The returned bytes are exactly what a resume would paint; no input is ever
  /// delivered to the session. The node enforces that the caller owns it.
  Future<SessionScreenResult> peekSession({
    required String nodeId,
    required String sessionRef,
  }) {
    _ensureConnected();
    final id = newId();
    final completer = Completer<SessionScreenResult>();
    _pendingSessionScreens[id] = completer;
    _connection!.send(
      ControlFrame(
        SessionScreenRequest(
          requestId: id,
          nodeId: nodeId,
          sessionRef: sessionRef,
        ),
      ),
    );
    return completer.future;
  }

  /// Detaches one of the caller's *active* sessions on [nodeId] from this
  /// connection — used to leave a session whose terminal is busy with a
  /// full-screen program. [sessionRef] is a full id, short handle or prefix;
  /// leave it empty to detach the sole active session. The attached client is
  /// disconnected by the node.
  Future<ActiveSessionDetachResult> detachActiveSession({
    required String nodeId,
    String sessionRef = '',
    Duration? timeout,
  }) {
    _ensureConnected();
    final id = newId();
    final completer = Completer<ActiveSessionDetachResult>();
    _pendingActiveDetach[id] = completer;
    _connection!.send(
      ControlFrame(
        ActiveSessionDetachRequest(
          requestId: id,
          nodeId: nodeId,
          sessionRef: sessionRef,
          timeoutSeconds: timeout?.inSeconds,
        ),
      ),
    );
    return completer.future;
  }

  /// Terminates one of the caller's sessions on [nodeId] — **running** (attached)
  /// or detached — named by [sessionRef] (a full id, short handle, or
  /// unambiguous prefix). Killing a running session disconnects its attached
  /// client; the node enforces that the caller owns the session.
  Future<DetachedSessionKillResult> killSession({
    required String nodeId,
    required String sessionRef,
  }) {
    _ensureConnected();
    final id = newId();
    final completer = Completer<DetachedSessionKillResult>();
    _pendingSessionKills[id] = completer;
    _connection!.send(
      ControlFrame(
        DetachedSessionKillRequest(
          requestId: id,
          nodeId: nodeId,
          sessionRef: sessionRef,
        ),
      ),
    );
    return completer.future;
  }

  /// Deprecated alias for [killSession] (which now also terminates running
  /// sessions, not just detached ones).
  Future<DetachedSessionKillResult> killDetachedSession({
    required String nodeId,
    required String sessionRef,
  }) => killSession(nodeId: nodeId, sessionRef: sessionRef);

  /// Runs [command] to completion on [nodeId], capturing its output.
  Future<ExecResult> execute({
    required String nodeId,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    String? cwd,
    ShellFamily? shellFamily,
  }) async {
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    final code = await executeStreaming(
      nodeId: nodeId,
      command: command,
      args: args,
      env: env,
      cwd: cwd,
      shellFamily: shellFamily,
      onStdout: out.add,
      onStderr: err.add,
    );
    return ExecResult(
      exitCode: code,
      stdout: out.takeBytes(),
      stderr: err.takeBytes(),
    );
  }

  /// Runs [command] on [nodeId] and forwards its output live: each stdout/stderr
  /// chunk is delivered to [onStdout]/[onStderr] as it arrives, rather than being
  /// buffered until the command exits. Returns the process exit code.
  ///
  /// Use this for long-running commands where progress should appear in real
  /// time; [execute] is the buffered variant built on top of this.
  Future<int> executeStreaming({
    required String nodeId,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    String? cwd,
    ShellFamily? shellFamily,
    required void Function(List<int> chunk) onStdout,
    required void Function(List<int> chunk) onStderr,
  }) async {
    final session = await openSession(
      nodeId: nodeId,
      mode: SessionMode.exec,
      command: command,
      args: args,
      env: env,
      cwd: cwd,
      shellFamily: shellFamily,
    );
    // Replenish the node's send window for the bytes we consume. The channel
    // grants a finite credit (256 KiB shared across stdout+stderr); without
    // this, a command producing more than that drains the credit and its output
    // stalls permanently. The node's credit counter is shared, so granting on
    // the stdout stream covers stderr bytes too.
    final outDone = session.stdout.forEach((chunk) {
      if (chunk.isNotEmpty) session.grantWindow(chunk.length);
      onStdout(chunk);
    });
    final errDone = session.stderr.forEach((chunk) {
      if (chunk.isNotEmpty) session.grantWindow(chunk.length);
      onStderr(chunk);
    });
    final code = await session.exitCode;
    await Future.wait([outDone, errDone]).catchError((_) => const <void>[]);
    return code;
  }

  void _onDisconnected() {
    _principal = null;
    if (_auth != null && !_auth!.isCompleted) {
      _auth!.completeError(const TransportException('Disconnected from Hub'));
    }
    for (final completer in _pendingNodeLists) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingNodeLists.clear();
    for (final completer in _pendingPings.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingPings.clear();
    for (final completer in _pendingSessionLists.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingSessionLists.clear();
    for (final completer in _pendingSessionKills.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingSessionKills.clear();
    for (final completer in _pendingActiveDetach.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingActiveDetach.clear();
    for (final completer in _pendingSessionScreens.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingSessionScreens.clear();
    for (final pending in _pendingTunnelOpens.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          const TransportException('Disconnected'),
        );
      }
    }
    _pendingTunnelOpens.clear();
    for (final completer in _pendingTunnelLists.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingTunnelLists.clear();
    for (final completer in _pendingTunnelCloses.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingTunnelCloses.clear();
    for (final completer in _pendingAiConfigs.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingAiConfigs.clear();
    for (final completer in _pendingHttpProxies.values) {
      if (!completer.isCompleted) {
        completer.completeError(const TransportException('Disconnected'));
      }
    }
    _pendingHttpProxies.clear();
    for (final bridge in _clientTunnels.values.toList()) {
      unawaited(bridge.close());
    }
    _clientTunnels.clear();
    config.onDisconnected?.call();
  }

  /// Opens a tunnel that exposes [targetPort] — reachable by [nodeId], or this
  /// client's own machine when [local] is set — on a public Hub port. When
  /// [publicPort] is given the Hub validates it against its configured range;
  /// otherwise the Hub allocates one in range. Completes once the Hub confirms,
  /// or throws [TunnelRejectedException] if refused.
  ///
  /// For a [local] tunnel this client must stay connected to serve the forwarded
  /// connections (it dials its own [targetHost]:[targetPort] for each).
  Future<TunnelHandle> openTunnel({
    required int targetPort,
    String nodeId = '',
    String targetHost = 'localhost',
    int? publicPort,
    bool local = false,
    bool secure = false,
  }) {
    _ensureConnected();
    final id = newId();
    final effectiveNode = local ? TunnelOpenRequest.localNode : nodeId;
    final completer = Completer<TunnelHandle>();
    _pendingTunnelOpens[id] = (
      completer: completer,
      nodeId: effectiveNode,
      targetPort: targetPort,
    );
    _connection!.send(
      ControlFrame(
        TunnelOpenRequest(
          requestId: id,
          nodeId: effectiveNode,
          targetHost: targetHost,
          targetPort: targetPort,
          publicPort: publicPort,
          secure: secure,
        ),
      ),
    );
    return completer.future;
  }

  /// Lists the caller's active tunnels held by the Hub.
  Future<List<TunnelInfo>> listTunnels() {
    _ensureConnected();
    final id = newId();
    final completer = Completer<List<TunnelInfo>>();
    _pendingTunnelLists[id] = completer;
    _connection!.send(ControlFrame(TunnelListRequest(requestId: id)));
    return completer.future;
  }

  /// Closes the caller's tunnel [tunnelRef] (a full id or unambiguous prefix).
  Future<TunnelCloseResult> closeTunnel(String tunnelRef) {
    _ensureConnected();
    final id = newId();
    final completer = Completer<TunnelCloseResult>();
    _pendingTunnelCloses[id] = completer;
    _connection!.send(
      ControlFrame(TunnelCloseRequest(requestId: id, tunnelRef: tunnelRef)),
    );
    return completer.future;
  }

  /// Serves a Hub-forwarded tunnel connection against this client's own machine
  /// (the `@local` case): adopt the channel, dial the local target and bridge
  /// bytes both ways.
  Future<void> _onTunnelConnect(NodeTunnelConnect connect) async {
    final mux = _mux;
    if (mux == null) return;
    final channel = mux.adopt(connect.channel);
    final bridge = localTunnelBridgeFactory(
      channel: channel,
      targetHost: connect.targetHost,
      targetPort: connect.targetPort,
      onClose: () async {
        _clientTunnels.remove(connect.channel);
        await mux.closeChannel(connect.channel);
      },
    );
    _clientTunnels[connect.channel] = bridge;
    final ok = await bridge.connect();
    if (ok) {
      _connection?.send(
        ControlFrame(
          NodeTunnelConnected(
            channel: connect.channel,
            tunnelId: connect.tunnelId,
          ),
        ),
      );
    } else {
      _clientTunnels.remove(connect.channel);
      _connection?.send(
        ControlFrame(
          NodeTunnelConnectFailed(
            channel: connect.channel,
            tunnelId: connect.tunnelId,
            reason: 'dial_failed',
            message:
                'could not reach ${connect.targetHost}:${connect.targetPort}',
          ),
        ),
      );
      await mux.closeChannel(connect.channel);
    }
  }

  void _ensureConnected() {
    if (_connection == null || !_connection!.isOpen) {
      throw const TransportException('Client is not connected');
    }
  }

  /// Disconnects from the Hub and releases resources.
  Future<void> close() async {
    await _controlSub?.cancel();
    await _mux?.dispose();
    await _connection?.close();
    _connection = null;
    _mux = null;
    _principal = null;
  }
}
