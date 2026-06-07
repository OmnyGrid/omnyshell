import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/auth/principal.dart';
import '../../domain/backend/pty_spec.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../domain/entities/session.dart';
import '../../domain/value_objects/principal_id.dart';
import '../../infrastructure/auth/credential_provider.dart';
import '../../infrastructure/transport/web_socket_connection.dart';
import '../../protocol/channel.dart';
import '../../protocol/channel_multiplexer.dart';
import '../../protocol/control_message.dart';
import '../../protocol/omnyshell_frame.dart';
import '../../protocol/protocol_version.dart';
import '../../shared/errors/omnyshell_exception.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/id_generator.dart';
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

/// Configuration for a [ClientRuntime].
class ClientConfig {
  /// The Hub WebSocket URL (`wss://host:port/...`).
  final Uri hubUri;

  /// How the client authenticates to the Hub.
  final CredentialProvider credentials;

  /// TLS trust roots for verifying the Hub certificate.
  final SecurityContext? securityContext;

  /// Optional TLS certificate override (pinning / self-signed test certs).
  /// `null` enforces standard verification.
  final bool Function(X509Certificate cert, String host, int port)?
  onBadCertificate;

  /// The clock (overridable in tests).
  final Clock clock;

  /// Optional diagnostic logger.
  final void Function(String message)? logger;

  /// Creates a client configuration.
  ClientConfig({
    required this.hubUri,
    required this.credentials,
    this.securityContext,
    this.onBadCertificate,
    this.clock = const SystemClock(),
    this.logger,
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

  WebSocketConnection? _connection;
  ChannelMultiplexer? _mux;
  StreamSubscription? _controlSub;
  Principal? _principal;
  Completer<void>? _auth;

  final Queue<Completer<List<NodeDescriptor>>> _pendingNodeLists = Queue();
  final Map<String, Completer<Duration>> _pendingPings = {};

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
    final WebSocketConnection connection;
    try {
      connection = await WebSocketConnection.connect(
        config.hubUri,
        securityContext: config.securityContext,
        onBadCertificate: config.onBadCertificate,
      );
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

  /// Runs [command] to completion on [nodeId], capturing its output.
  Future<ExecResult> execute({
    required String nodeId,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    String? cwd,
  }) async {
    final session = await openSession(
      nodeId: nodeId,
      mode: SessionMode.exec,
      command: command,
      args: args,
      env: env,
      cwd: cwd,
    );
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    final outDone = session.stdout.forEach(out.add);
    final errDone = session.stderr.forEach(err.add);
    final code = await session.exitCode;
    await Future.wait([outDone, errDone]).catchError((_) => const <void>[]);
    return ExecResult(
      exitCode: code,
      stdout: out.takeBytes(),
      stderr: err.takeBytes(),
    );
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
