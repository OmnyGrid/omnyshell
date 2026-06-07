import 'package:meta/meta.dart';

import '../domain/backend/pty_spec.dart';
import '../domain/entities/node_capabilities.dart';
import '../domain/entities/node_descriptor.dart';
import '../domain/entities/platform_info.dart';
import '../domain/entities/session.dart';
import '../domain/value_objects/node_id.dart';
import '../domain/value_objects/omny_uid.dart';
import '../shared/json/json_codec_helpers.dart';

/// Base class for every structured control message.
///
/// Control messages travel as JSON on WebSocket text frames inside the envelope
/// `{"t": <type>, "c": <channelId?>, "d": <payload>}`. Each subtype exposes a
/// stable [type] discriminator, an optional [channelId] (the `c` field, set for
/// channel-scoped messages), and a [toJson] payload (the `d` field). Decoding is
/// handled by `FrameCodec`'s registry. The hierarchy is `sealed` so handlers can
/// switch exhaustively.
@immutable
sealed class ControlMessage {
  /// Base constructor.
  const ControlMessage();

  /// The stable type discriminator (the envelope `t` field).
  String get type;

  /// The channel this message pertains to, or `null` for connection-level
  /// messages (the envelope `c` field).
  int? get channelId => null;

  /// The message payload (the envelope `d` field), without the type or channel.
  Map<String, dynamic> toJson();
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

/// First frame after the WebSocket upgrade. The Hub sends `hello` with a
/// single-use [nonce]; the peer replies with its role and capabilities.
final class Hello extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'hello';

  /// `hub`, `node` or `client`.
  final String role;

  /// The sender's protocol version.
  final int protocolVersion;

  /// The lowest protocol version the sender accepts.
  final int minVersion;

  /// The per-connection challenge nonce (base64), set by the Hub; signed by
  /// public-key credentials. `null` on the peer's own hello.
  final String? nonce;

  /// Free-form sender info (agent name/version), advisory only.
  final Map<String, dynamic> info;

  /// Creates a hello.
  const Hello({
    required this.role,
    required this.protocolVersion,
    required this.minVersion,
    this.nonce,
    this.info = const {},
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'role': role,
    'protocolVersion': protocolVersion,
    'minVersion': minVersion,
    if (nonce != null) 'nonce': nonce,
    if (info.isNotEmpty) 'info': info,
  };

  /// Decodes a [Hello].
  static Hello fromJson(int? channel, Map<String, dynamic> d) => Hello(
    role: Json.requireString(d, 'role'),
    protocolVersion: Json.requireInt(d, 'protocolVersion'),
    minVersion: Json.optInt(d, 'minVersion', 1)!,
    nonce: Json.optString(d, 'nonce'),
    info: d['info'] is Map
        ? (d['info'] as Map).cast<String, dynamic>()
        : const {},
  );
}

/// A login attempt presenting a credential.
final class AuthRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'auth.request';

  /// `publicKey` or `token`.
  final String method;

  /// The claimed principal (login name).
  final String principal;

  /// Bearer token (token method).
  final String? token;

  /// Base64 Ed25519 public key (publicKey method).
  final String? publicKey;

  /// Base64 Ed25519 signature over the connection nonce (publicKey method).
  final String? signature;

  /// Creates an auth request.
  const AuthRequest({
    required this.method,
    required this.principal,
    this.token,
    this.publicKey,
    this.signature,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'method': method,
    'principal': principal,
    if (token != null) 'token': token,
    if (publicKey != null) 'publicKey': publicKey,
    if (signature != null) 'signature': signature,
  };

  /// Decodes an [AuthRequest].
  static AuthRequest fromJson(int? channel, Map<String, dynamic> d) =>
      AuthRequest(
        method: Json.requireString(d, 'method'),
        principal: Json.requireString(d, 'principal'),
        token: Json.optString(d, 'token'),
        publicKey: Json.optString(d, 'publicKey'),
        signature: Json.optString(d, 'signature'),
      );
}

/// Successful authentication, carrying the resolved identity and a session
/// token bound to this connection.
final class AuthOk extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'auth.ok';

  /// The resolved principal id.
  final String principal;

  /// The principal's display name.
  final String displayName;

  /// The principal's roles.
  final List<String> roles;

  /// An opaque token identifying this authenticated connection.
  final String sessionToken;

  /// Creates an auth-ok.
  const AuthOk({
    required this.principal,
    required this.displayName,
    required this.roles,
    required this.sessionToken,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'principal': principal,
    'displayName': displayName,
    'roles': roles,
    'sessionToken': sessionToken,
  };

  /// Decodes an [AuthOk].
  static AuthOk fromJson(int? channel, Map<String, dynamic> d) => AuthOk(
    principal: Json.requireString(d, 'principal'),
    displayName: Json.optString(d, 'displayName') ?? '',
    roles: Json.optStringList(d, 'roles'),
    sessionToken: Json.requireString(d, 'sessionToken'),
  );
}

/// Failed authentication.
final class AuthFail extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'auth.fail';

  /// A short machine reason (e.g. `invalid_signature`, `unknown_principal`).
  final String reason;

  /// A human-readable message.
  final String message;

  /// Creates an auth-fail.
  const AuthFail({required this.reason, required this.message});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'reason': reason, 'message': message};

  /// Decodes an [AuthFail].
  static AuthFail fromJson(int? channel, Map<String, dynamic> d) => AuthFail(
    reason: Json.optString(d, 'reason') ?? 'auth_failed',
    message: Json.optString(d, 'message') ?? 'Authentication failed',
  );
}

// ---------------------------------------------------------------------------
// Node lifecycle
// ---------------------------------------------------------------------------

/// Node → Hub: registers the node's identity and platform.
final class NodeRegister extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.register';

  /// The node id.
  final String nodeId;

  /// The deterministic global UID the node computed for itself, or `null` for
  /// older nodes that do not report one.
  final String? uid;

  /// A human-friendly display name.
  final String displayName;

  /// The node platform.
  final PlatformInfo platform;

  /// Operator labels.
  final Map<String, String> labels;

  /// Creates a register message.
  const NodeRegister({
    required this.nodeId,
    required this.displayName,
    required this.platform,
    this.uid,
    this.labels = const {},
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    if (uid != null) 'uid': uid,
    'displayName': displayName,
    'platform': platform.toJson(),
    'labels': labels,
  };

  /// Decodes a [NodeRegister].
  static NodeRegister fromJson(int? channel, Map<String, dynamic> d) =>
      NodeRegister(
        nodeId: Json.requireString(d, 'nodeId'),
        uid: Json.optString(d, 'uid'),
        displayName: Json.optString(d, 'displayName') ?? '',
        platform: PlatformInfo.fromJson(Json.asObject(d['platform'])),
        labels: Json.optStringMap(d, 'labels'),
      );

  /// Builds the public [NodeDescriptor] this registration describes (offline
  /// until the Hub marks it online).
  NodeDescriptor toDescriptor() => NodeDescriptor(
    id: NodeId(nodeId),
    uid: uid == null ? null : OmnyUid(uid!),
    displayName: displayName,
    platform: platform,
    labels: labels,
    online: false,
  );
}

/// Hub → Node: confirms registration.
final class NodeRegistered extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.registered';

  /// The registered node id.
  final String nodeId;

  /// When the Hub recorded the registration.
  final DateTime assignedAt;

  /// Creates a registered message.
  const NodeRegistered({required this.nodeId, required this.assignedAt});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'assignedAt': assignedAt.toUtc().toIso8601String(),
  };

  /// Decodes a [NodeRegistered].
  static NodeRegistered fromJson(int? channel, Map<String, dynamic> d) =>
      NodeRegistered(
        nodeId: Json.requireString(d, 'nodeId'),
        assignedAt: Json.requireTimestamp(d, 'assignedAt'),
      );
}

/// Node → Hub: advertises capabilities after registration.
final class NodeCapabilitiesMessage extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.capabilities';

  /// The advertised capabilities.
  final NodeCapabilities capabilities;

  /// Creates a capabilities message.
  const NodeCapabilitiesMessage(this.capabilities);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => capabilities.toJson();

  /// Decodes a [NodeCapabilitiesMessage].
  static NodeCapabilitiesMessage fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeCapabilitiesMessage(NodeCapabilities.fromJson(d));
}

/// Node → Hub: periodic liveness signal with a monotonic sequence number.
final class NodeHeartbeat extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.heartbeat';

  /// The reporting node id.
  final String nodeId;

  /// Number of sessions currently active on the node.
  final int activeSessions;

  /// Strictly-increasing sequence number (replay/stall detection).
  final int seq;

  /// When the heartbeat was produced.
  final DateTime ts;

  /// Creates a heartbeat.
  const NodeHeartbeat({
    required this.nodeId,
    required this.activeSessions,
    required this.seq,
    required this.ts,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'activeSessions': activeSessions,
    'seq': seq,
    'ts': ts.toUtc().toIso8601String(),
  };

  /// Decodes a [NodeHeartbeat].
  static NodeHeartbeat fromJson(int? channel, Map<String, dynamic> d) =>
      NodeHeartbeat(
        nodeId: Json.requireString(d, 'nodeId'),
        activeSessions: Json.optInt(d, 'activeSessions', 0)!,
        seq: Json.requireInt(d, 'seq'),
        ts: Json.requireTimestamp(d, 'ts'),
      );
}

/// Hub → Node: acknowledges a heartbeat.
final class NodeHeartbeatAck extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.heartbeat.ack';

  /// The acknowledged sequence number.
  final int seq;

  /// The Hub's clock at ack time.
  final DateTime ts;

  /// Creates a heartbeat ack.
  const NodeHeartbeatAck({required this.seq, required this.ts});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'seq': seq,
    'ts': ts.toUtc().toIso8601String(),
  };

  /// Decodes a [NodeHeartbeatAck].
  static NodeHeartbeatAck fromJson(int? channel, Map<String, dynamic> d) =>
      NodeHeartbeatAck(
        seq: Json.requireInt(d, 'seq'),
        ts: Json.requireTimestamp(d, 'ts'),
      );
}

// ---------------------------------------------------------------------------
// Keepalive
// ---------------------------------------------------------------------------

/// Application-level keepalive request, used to measure round-trip latency and
/// detect half-open connections.
final class Ping extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'ping';

  /// A correlation id echoed in the matching [Pong].
  final String id;

  /// The sender's clock when the ping was sent.
  final DateTime ts;

  /// Creates a ping.
  const Ping({required this.id, required this.ts});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': ts.toUtc().toIso8601String(),
  };

  /// Decodes a [Ping].
  static Ping fromJson(int? channel, Map<String, dynamic> d) =>
      Ping(id: Json.requireString(d, 'id'), ts: Json.requireTimestamp(d, 'ts'));
}

/// Reply to a [Ping].
final class Pong extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'pong';

  /// The correlation id from the ping.
  final String id;

  /// The original ping timestamp, echoed back.
  final DateTime ts;

  /// The responder's clock at reply time.
  final DateTime serverTs;

  /// Creates a pong.
  const Pong({required this.id, required this.ts, required this.serverTs});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': ts.toUtc().toIso8601String(),
    'serverTs': serverTs.toUtc().toIso8601String(),
  };

  /// Decodes a [Pong].
  static Pong fromJson(int? channel, Map<String, dynamic> d) => Pong(
    id: Json.requireString(d, 'id'),
    ts: Json.requireTimestamp(d, 'ts'),
    serverTs: Json.requireTimestamp(d, 'serverTs'),
  );
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// Client → Hub: requests the list of nodes the client may see.
final class NodeListRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.list.request';

  /// Optional discovery filters (e.g. `{label: 'env=prod'}`).
  final Map<String, String> filter;

  /// Creates a node-list request.
  const NodeListRequest({this.filter = const {}});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {if (filter.isNotEmpty) 'filter': filter};

  /// Decodes a [NodeListRequest].
  static NodeListRequest fromJson(int? channel, Map<String, dynamic> d) =>
      NodeListRequest(filter: Json.optStringMap(d, 'filter'));
}

/// Hub → Client: the discovered nodes.
final class NodeListResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.list.response';

  /// The visible nodes.
  final List<NodeDescriptor> nodes;

  /// Creates a node-list response.
  const NodeListResponse(this.nodes);

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };

  /// Decodes a [NodeListResponse].
  static NodeListResponse fromJson(int? channel, Map<String, dynamic> d) {
    final raw = d['nodes'];
    final list = raw is List ? raw : const [];
    return NodeListResponse([
      for (final n in list) NodeDescriptor.fromJson(Json.asObject(n)),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Session establishment
// ---------------------------------------------------------------------------

/// Client → Hub: opens a session on a node over a new client channel.
final class SessionOpen extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'session.open';

  /// The client-allocated channel id.
  final int channel;

  /// The target node.
  final String nodeId;

  /// Exec or interactive shell.
  final SessionMode mode;

  /// The command to run (exec) or shell to launch (shell); may be `null`.
  final String? command;

  /// Command arguments.
  final List<String> args;

  /// Extra environment variables.
  final Map<String, String> env;

  /// Working directory; `null` for the node default.
  final String? cwd;

  /// Requested terminal geometry for interactive shells.
  final PtySpec? pty;

  /// Creates a session-open.
  const SessionOpen({
    required this.channel,
    required this.nodeId,
    required this.mode,
    this.command,
    this.args = const [],
    this.env = const {},
    this.cwd,
    this.pty,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'mode': mode.name,
    if (command != null) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (env.isNotEmpty) 'env': env,
    if (cwd != null) 'cwd': cwd,
    if (pty != null) 'pty': pty!.toJson(),
  };

  /// Decodes a [SessionOpen].
  static SessionOpen fromJson(int? channel, Map<String, dynamic> d) {
    final pty = d['pty'];
    return SessionOpen(
      channel: channel ?? (throw _missingChannel(typeName)),
      nodeId: Json.requireString(d, 'nodeId'),
      mode: SessionMode.parse(Json.optString(d, 'mode') ?? 'exec'),
      command: Json.optString(d, 'command'),
      args: Json.optStringList(d, 'args'),
      env: Json.optStringMap(d, 'env'),
      cwd: Json.optString(d, 'cwd'),
      pty: pty == null ? null : PtySpec.fromJson(Json.asObject(pty)),
    );
  }
}

/// Hub → Client: the session is open.
final class SessionOpened extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'session.opened';

  /// The client channel id.
  final int channel;

  /// The minted session id.
  final String sessionId;

  /// Whether a PTY was allocated.
  final bool pty;

  /// Creates a session-opened.
  const SessionOpened({
    required this.channel,
    required this.sessionId,
    this.pty = false,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {'sessionId': sessionId, 'pty': pty};

  /// Decodes a [SessionOpened].
  static SessionOpened fromJson(int? channel, Map<String, dynamic> d) =>
      SessionOpened(
        channel: channel ?? (throw _missingChannel(typeName)),
        sessionId: Json.requireString(d, 'sessionId'),
        pty: Json.optBool(d, 'pty'),
      );
}

/// Hub → Client (or Node → Hub via [NodeSessionRejected]): the session could
/// not be opened.
final class SessionRejected extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'session.rejected';

  /// The client channel id.
  final int channel;

  /// A machine reason (see `ErrorCodes`).
  final String reason;

  /// A human-readable message.
  final String message;

  /// Creates a session-rejected.
  const SessionRejected({
    required this.channel,
    required this.reason,
    required this.message,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {'reason': reason, 'message': message};

  /// Decodes a [SessionRejected].
  static SessionRejected fromJson(int? channel, Map<String, dynamic> d) =>
      SessionRejected(
        channel: channel ?? (throw _missingChannel(typeName)),
        reason: Json.optString(d, 'reason') ?? 'session_rejected',
        message: Json.optString(d, 'message') ?? 'Session rejected',
      );
}

/// Hub → Node: instructs the node to start a session on a node-side channel.
final class NodeSessionOpen extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.session.open';

  /// The hub-allocated node-side channel id.
  final int channel;

  /// The minted session id.
  final String sessionId;

  /// The authenticated principal opening the session.
  final String principal;

  /// Exec or interactive shell.
  final SessionMode mode;

  /// The command or shell.
  final String? command;

  /// Command arguments.
  final List<String> args;

  /// Extra environment variables.
  final Map<String, String> env;

  /// Working directory.
  final String? cwd;

  /// Requested terminal geometry.
  final PtySpec? pty;

  /// Creates a node-session-open.
  const NodeSessionOpen({
    required this.channel,
    required this.sessionId,
    required this.principal,
    required this.mode,
    this.command,
    this.args = const [],
    this.env = const {},
    this.cwd,
    this.pty,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'principal': principal,
    'mode': mode.name,
    if (command != null) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (env.isNotEmpty) 'env': env,
    if (cwd != null) 'cwd': cwd,
    if (pty != null) 'pty': pty!.toJson(),
  };

  /// Decodes a [NodeSessionOpen].
  static NodeSessionOpen fromJson(int? channel, Map<String, dynamic> d) {
    final pty = d['pty'];
    return NodeSessionOpen(
      channel: channel ?? (throw _missingChannel(typeName)),
      sessionId: Json.requireString(d, 'sessionId'),
      principal: Json.requireString(d, 'principal'),
      mode: SessionMode.parse(Json.optString(d, 'mode') ?? 'exec'),
      command: Json.optString(d, 'command'),
      args: Json.optStringList(d, 'args'),
      env: Json.optStringMap(d, 'env'),
      cwd: Json.optString(d, 'cwd'),
      pty: pty == null ? null : PtySpec.fromJson(Json.asObject(pty)),
    );
  }
}

/// Node → Hub: the node accepted and started the session.
final class NodeSessionOpened extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.session.opened';

  /// The node-side channel id.
  final int channel;

  /// The session id.
  final String sessionId;

  /// The backend process id, if known.
  final int? pid;

  /// Creates a node-session-opened.
  const NodeSessionOpened({
    required this.channel,
    required this.sessionId,
    this.pid,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    if (pid != null) 'pid': pid,
  };

  /// Decodes a [NodeSessionOpened].
  static NodeSessionOpened fromJson(int? channel, Map<String, dynamic> d) =>
      NodeSessionOpened(
        channel: channel ?? (throw _missingChannel(typeName)),
        sessionId: Json.requireString(d, 'sessionId'),
        pid: Json.optInt(d, 'pid'),
      );
}

/// Node → Hub: the node refused the session.
final class NodeSessionRejected extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.session.rejected';

  /// The node-side channel id.
  final int channel;

  /// The session id.
  final String sessionId;

  /// A machine reason.
  final String reason;

  /// A human-readable message.
  final String message;

  /// Creates a node-session-rejected.
  const NodeSessionRejected({
    required this.channel,
    required this.sessionId,
    required this.reason,
    required this.message,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'reason': reason,
    'message': message,
  };

  /// Decodes a [NodeSessionRejected].
  static NodeSessionRejected fromJson(int? channel, Map<String, dynamic> d) =>
      NodeSessionRejected(
        channel: channel ?? (throw _missingChannel(typeName)),
        sessionId: Json.optString(d, 'sessionId') ?? '',
        reason: Json.optString(d, 'reason') ?? 'session_rejected',
        message: Json.optString(d, 'message') ?? 'Session rejected',
      );
}

// ---------------------------------------------------------------------------
// Channel control
// ---------------------------------------------------------------------------

/// Resize the terminal of an interactive session.
final class ChannelResize extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'channel.resize';

  /// The channel id.
  final int channel;

  /// New width in columns.
  final int cols;

  /// New height in rows.
  final int rows;

  /// Creates a resize.
  const ChannelResize({
    required this.channel,
    required this.cols,
    required this.rows,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {'cols': cols, 'rows': rows};

  /// Decodes a [ChannelResize].
  static ChannelResize fromJson(int? channel, Map<String, dynamic> d) =>
      ChannelResize(
        channel: channel ?? (throw _missingChannel(typeName)),
        cols: Json.optInt(d, 'cols', 80)!,
        rows: Json.optInt(d, 'rows', 24)!,
      );
}

/// Deliver a POSIX signal to the session's process.
final class ChannelSignal extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'channel.signal';

  /// The channel id.
  final int channel;

  /// The signal name (e.g. `SIGINT`).
  final String signal;

  /// Creates a signal.
  const ChannelSignal({required this.channel, required this.signal});

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {'signal': signal};

  /// Decodes a [ChannelSignal].
  static ChannelSignal fromJson(int? channel, Map<String, dynamic> d) =>
      ChannelSignal(
        channel: channel ?? (throw _missingChannel(typeName)),
        signal: Json.requireString(d, 'signal'),
      );
}

/// Half-close a stream (typically stdin) on the channel.
final class ChannelEof extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'channel.eof';

  /// The channel id.
  final int channel;

  /// The stream being closed (`stdin`, `stdout`, `stderr`).
  final String stream;

  /// Creates an eof.
  const ChannelEof({required this.channel, this.stream = 'stdin'});

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {'stream': stream};

  /// Decodes a [ChannelEof].
  static ChannelEof fromJson(int? channel, Map<String, dynamic> d) =>
      ChannelEof(
        channel: channel ?? (throw _missingChannel(typeName)),
        stream: Json.optString(d, 'stream') ?? 'stdin',
      );
}

/// Node → Client: the process exited.
final class ChannelExit extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'channel.exit';

  /// The channel id.
  final int channel;

  /// The process exit code.
  final int exitCode;

  /// The terminating signal name, if the process was killed by a signal.
  final String? signal;

  /// When the process exited.
  final DateTime ts;

  /// Creates an exit.
  const ChannelExit({
    required this.channel,
    required this.exitCode,
    required this.ts,
    this.signal,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'exitCode': exitCode,
    if (signal != null) 'signal': signal,
    'ts': ts.toUtc().toIso8601String(),
  };

  /// Decodes a [ChannelExit].
  static ChannelExit fromJson(int? channel, Map<String, dynamic> d) =>
      ChannelExit(
        channel: channel ?? (throw _missingChannel(typeName)),
        exitCode: Json.optInt(d, 'exitCode', 0)!,
        signal: Json.optString(d, 'signal'),
        ts: Json.optTimestamp(d, 'ts') ?? DateTime.now().toUtc(),
      );
}

/// Tear down a channel.
final class ChannelClose extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'channel.close';

  /// The channel id.
  final int channel;

  /// A machine reason (`normal`, `client_closed`, `node_closed`, `error`).
  final String reason;

  /// An optional human-readable message.
  final String? message;

  /// Creates a close.
  const ChannelClose({
    required this.channel,
    this.reason = 'normal',
    this.message,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'reason': reason,
    if (message != null) 'message': message,
  };

  /// Decodes a [ChannelClose].
  static ChannelClose fromJson(int? channel, Map<String, dynamic> d) =>
      ChannelClose(
        channel: channel ?? (throw _missingChannel(typeName)),
        reason: Json.optString(d, 'reason') ?? 'normal',
        message: Json.optString(d, 'message'),
      );
}

/// Backpressure credit grant for a stream on a channel.
final class ChannelWindow extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'channel.window';

  /// The channel id.
  final int channel;

  /// The stream the credit applies to (`stdin`, `stdout`, `stderr`).
  final String stream;

  /// Additional bytes the receiver is now willing to accept.
  final int credit;

  /// Creates a window update.
  const ChannelWindow({
    required this.channel,
    required this.stream,
    required this.credit,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {'stream': stream, 'credit': credit};

  /// Decodes a [ChannelWindow].
  static ChannelWindow fromJson(int? channel, Map<String, dynamic> d) =>
      ChannelWindow(
        channel: channel ?? (throw _missingChannel(typeName)),
        stream: Json.optString(d, 'stream') ?? 'stdout',
        credit: Json.requireInt(d, 'credit'),
      );
}

/// A connection- or channel-level error.
final class ProtocolError extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'error';

  /// A stable error code (see `ErrorCodes`).
  final String code;

  /// A human-readable message.
  final String message;

  /// Whether the error is fatal (the sender will close the connection).
  final bool fatal;

  /// The channel the error pertains to, if any.
  final int? channel;

  /// Creates a protocol error.
  const ProtocolError({
    required this.code,
    required this.message,
    this.fatal = false,
    this.channel,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    'fatal': fatal,
  };

  /// Decodes a [ProtocolError].
  static ProtocolError fromJson(int? channel, Map<String, dynamic> d) =>
      ProtocolError(
        code: Json.optString(d, 'code') ?? 'protocol_error',
        message: Json.optString(d, 'message') ?? 'Protocol error',
        fatal: Json.optBool(d, 'fatal'),
        channel: channel,
      );
}

FormatException _missingChannel(String type) =>
    FormatException("Control message '$type' requires a channel id");
