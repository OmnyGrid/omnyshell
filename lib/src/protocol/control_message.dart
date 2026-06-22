import 'package:meta/meta.dart';

import '../domain/backend/pty_spec.dart';
import '../domain/backend/shell_family.dart';
import '../domain/entities/detached_session_info.dart';
import '../domain/entities/node_capabilities.dart';
import '../domain/entities/node_descriptor.dart';
import '../domain/entities/platform_info.dart';
import '../domain/entities/session.dart';
import '../domain/entities/tunnel_info.dart';
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

  /// When set, resume the existing detached session identified by this id (or
  /// unambiguous prefix) instead of starting a new shell. The node enforces
  /// that the resuming principal owns the session.
  final String? resumeSessionId;

  /// For exec mode: run the command under this shell family's interpreter on
  /// the node (see [ShellRequest.shellFamily]); `null` uses the node default.
  final ShellFamily? shellFamily;

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
    this.resumeSessionId,
    this.shellFamily,
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
    if (resumeSessionId != null) 'resumeSessionId': resumeSessionId,
    if (shellFamily != null) 'shellFamily': shellFamily!.wireName,
  };

  /// Decodes a [SessionOpen].
  static SessionOpen fromJson(int? channel, Map<String, dynamic> d) {
    final pty = d['pty'];
    final family = Json.optString(d, 'shellFamily');
    return SessionOpen(
      channel: channel ?? (throw _missingChannel(typeName)),
      nodeId: Json.requireString(d, 'nodeId'),
      mode: SessionMode.parse(Json.optString(d, 'mode') ?? 'exec'),
      command: Json.optString(d, 'command'),
      args: Json.optStringList(d, 'args'),
      env: Json.optStringMap(d, 'env'),
      cwd: Json.optString(d, 'cwd'),
      pty: pty == null ? null : PtySpec.fromJson(Json.asObject(pty)),
      resumeSessionId: Json.optString(d, 'resumeSessionId'),
      shellFamily: family == null ? null : ShellFamily.fromWire(family),
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

  /// Whether the (resumed) session is currently inside a full-screen program's
  /// alternate screen, so the client should attach in passthrough without
  /// priming a prompt.
  final bool altScreen;

  /// The command-language family of the remote shell (`posix`, `powershell`, or
  /// `cmd`), so the client speaks the matching marker/command dialect. Defaults
  /// to `posix` for backward compatibility with hubs/nodes that omit it.
  final String shell;

  /// Creates a session-opened.
  const SessionOpened({
    required this.channel,
    required this.sessionId,
    this.pty = false,
    this.altScreen = false,
    this.shell = 'posix',
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'pty': pty,
    if (altScreen) 'altScreen': true,
    if (shell != 'posix') 'shell': shell,
  };

  /// Decodes a [SessionOpened].
  static SessionOpened fromJson(int? channel, Map<String, dynamic> d) =>
      SessionOpened(
        channel: channel ?? (throw _missingChannel(typeName)),
        sessionId: Json.requireString(d, 'sessionId'),
        pty: Json.optBool(d, 'pty'),
        altScreen: Json.optBool(d, 'altScreen'),
        shell: Json.optString(d, 'shell') ?? 'posix',
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

  /// When set, the node resumes the existing detached session with this id (or
  /// unambiguous prefix), owned by [principal], instead of starting a shell.
  final String? resumeSessionId;

  /// For exec mode: run the command under this shell family's interpreter on
  /// the node (see [ShellRequest.shellFamily]); `null` uses the node default.
  final ShellFamily? shellFamily;

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
    this.resumeSessionId,
    this.shellFamily,
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
    if (resumeSessionId != null) 'resumeSessionId': resumeSessionId,
    if (shellFamily != null) 'shellFamily': shellFamily!.wireName,
  };

  /// Decodes a [NodeSessionOpen].
  static NodeSessionOpen fromJson(int? channel, Map<String, dynamic> d) {
    final pty = d['pty'];
    final family = Json.optString(d, 'shellFamily');
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
      resumeSessionId: Json.optString(d, 'resumeSessionId'),
      shellFamily: family == null ? null : ShellFamily.fromWire(family),
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

  /// Whether the (resumed) session is currently inside a full-screen program's
  /// alternate screen. Relayed to the client as [SessionOpened.altScreen].
  final bool altScreen;

  /// The command-language family of the launched shell (`posix`, `powershell`,
  /// or `cmd`). Relayed to the client as [SessionOpened.shell]; defaults to
  /// `posix` for older nodes that omit it.
  final String shell;

  /// Creates a node-session-opened.
  const NodeSessionOpened({
    required this.channel,
    required this.sessionId,
    this.pid,
    this.altScreen = false,
    this.shell = 'posix',
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    if (pid != null) 'pid': pid,
    if (altScreen) 'altScreen': true,
    if (shell != 'posix') 'shell': shell,
  };

  /// Decodes a [NodeSessionOpened].
  static NodeSessionOpened fromJson(int? channel, Map<String, dynamic> d) =>
      NodeSessionOpened(
        channel: channel ?? (throw _missingChannel(typeName)),
        sessionId: Json.requireString(d, 'sessionId'),
        pid: Json.optInt(d, 'pid'),
        altScreen: Json.optBool(d, 'altScreen'),
        shell: Json.optString(d, 'shell') ?? 'posix',
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

// ---------------------------------------------------------------------------
// Detachable sessions
// ---------------------------------------------------------------------------

/// Client → Hub: detach the live session on [channel], keeping the node-side
/// PTY/shell/processes running. Optional [timeoutSeconds] schedules automatic
/// cleanup; `null` keeps the session indefinitely.
final class SessionDetachRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'session.detach.request';

  /// The client channel id of the session to detach.
  final int channel;

  /// Seconds until the detached session expires, or `null` for indefinite.
  final int? timeoutSeconds;

  /// Creates a session-detach request.
  const SessionDetachRequest({required this.channel, this.timeoutSeconds});

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
  };

  /// Decodes a [SessionDetachRequest].
  static SessionDetachRequest fromJson(int? channel, Map<String, dynamic> d) =>
      SessionDetachRequest(
        channel: channel ?? (throw _missingChannel(typeName)),
        timeoutSeconds: Json.optInt(d, 'timeoutSeconds'),
      );
}

/// Hub → Node: detach the session on the node-side [channel], on behalf of
/// [principal]. Mirrors [SessionDetachRequest] across the relay.
final class NodeSessionDetach extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.session.detach';

  /// The node-side channel id.
  final int channel;

  /// The session id being detached.
  final String sessionId;

  /// The authenticated principal that owns the session.
  final String principal;

  /// Seconds until the detached session expires, or `null` for indefinite.
  final int? timeoutSeconds;

  /// Creates a node-session-detach.
  const NodeSessionDetach({
    required this.channel,
    required this.sessionId,
    required this.principal,
    this.timeoutSeconds,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'principal': principal,
    if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
  };

  /// Decodes a [NodeSessionDetach].
  static NodeSessionDetach fromJson(int? channel, Map<String, dynamic> d) =>
      NodeSessionDetach(
        channel: channel ?? (throw _missingChannel(typeName)),
        sessionId: Json.requireString(d, 'sessionId'),
        principal: Json.requireString(d, 'principal'),
        timeoutSeconds: Json.optInt(d, 'timeoutSeconds'),
      );
}

/// Node → Hub: the session was detached and now lives in the node registry.
final class NodeSessionDetached extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.session.detached';

  /// The node-side channel id (now closed).
  final int channel;

  /// The detached session id.
  final String sessionId;

  /// The short, display-only handle for the session.
  final String shortId;

  /// When the session expires, or `null` for indefinite.
  final DateTime? expiresAt;

  /// Creates a node-session-detached.
  const NodeSessionDetached({
    required this.channel,
    required this.sessionId,
    required this.shortId,
    this.expiresAt,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'shortId': shortId,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
  };

  /// Decodes a [NodeSessionDetached].
  static NodeSessionDetached fromJson(int? channel, Map<String, dynamic> d) =>
      NodeSessionDetached(
        channel: channel ?? (throw _missingChannel(typeName)),
        sessionId: Json.requireString(d, 'sessionId'),
        shortId: Json.optString(d, 'shortId') ?? '',
        expiresAt: Json.optTimestamp(d, 'expiresAt'),
      );
}

/// Hub → Client: the session was detached; resume it later by [shortId].
final class SessionDetached extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'session.detached';

  /// The client channel id (now closed).
  final int channel;

  /// The detached session id.
  final String sessionId;

  /// The short, display-only handle for the session.
  final String shortId;

  /// When the session expires, or `null` for indefinite.
  final DateTime? expiresAt;

  /// Creates a session-detached.
  const SessionDetached({
    required this.channel,
    required this.sessionId,
    required this.shortId,
    this.expiresAt,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'shortId': shortId,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
  };

  /// Decodes a [SessionDetached].
  static SessionDetached fromJson(int? channel, Map<String, dynamic> d) =>
      SessionDetached(
        channel: channel ?? (throw _missingChannel(typeName)),
        sessionId: Json.requireString(d, 'sessionId'),
        shortId: Json.optString(d, 'shortId') ?? '',
        expiresAt: Json.optTimestamp(d, 'expiresAt'),
      );
}

/// Client → Hub: list the caller's detached sessions on [nodeId]. Correlated to
/// the response by [requestId] (a connection-level request/response RPC).
final class DetachedSessionsRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'sessions.list.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The target node.
  final String nodeId;

  /// Creates a detached-sessions list request.
  const DetachedSessionsRequest({
    required this.requestId,
    required this.nodeId,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'requestId': requestId, 'nodeId': nodeId};

  /// Decodes a [DetachedSessionsRequest].
  static DetachedSessionsRequest fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => DetachedSessionsRequest(
    requestId: Json.requireString(d, 'requestId'),
    nodeId: Json.requireString(d, 'nodeId'),
  );
}

/// Hub → Node: list the [principal]'s detached sessions. Correlated by
/// [requestId].
final class NodeDetachedSessionsRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.sessions.list.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The owner whose sessions are listed.
  final String principal;

  /// Creates a node detached-sessions list request.
  const NodeDetachedSessionsRequest({
    required this.requestId,
    required this.principal,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'principal': principal,
  };

  /// Decodes a [NodeDetachedSessionsRequest].
  static NodeDetachedSessionsRequest fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeDetachedSessionsRequest(
    requestId: Json.requireString(d, 'requestId'),
    principal: Json.requireString(d, 'principal'),
  );
}

/// Node → Hub: the [principal]'s detached sessions. Correlated by [requestId].
final class NodeDetachedSessionsResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.sessions.list.response';

  /// The correlation id from the request.
  final String requestId;

  /// The matching detached sessions (already filtered by owner).
  final List<DetachedSessionInfo> sessions;

  /// Creates a node detached-sessions list response.
  const NodeDetachedSessionsResponse({
    required this.requestId,
    required this.sessions,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };

  /// Decodes a [NodeDetachedSessionsResponse].
  static NodeDetachedSessionsResponse fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeDetachedSessionsResponse(
    requestId: Json.requireString(d, 'requestId'),
    sessions: _decodeSessions(d['sessions']),
  );
}

/// Hub → Client: the caller's detached sessions. Correlated by [requestId].
final class DetachedSessionsResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'sessions.list.response';

  /// The correlation id from the request.
  final String requestId;

  /// The matching detached sessions.
  final List<DetachedSessionInfo> sessions;

  /// Creates a detached-sessions list response.
  const DetachedSessionsResponse({
    required this.requestId,
    required this.sessions,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };

  /// Decodes a [DetachedSessionsResponse].
  static DetachedSessionsResponse fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => DetachedSessionsResponse(
    requestId: Json.requireString(d, 'requestId'),
    sessions: _decodeSessions(d['sessions']),
  );
}

/// Client → Hub: terminate the caller's detached session [sessionRef] (an
/// unambiguous id or prefix) on [nodeId]. Correlated by [requestId].
final class DetachedSessionKillRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'sessions.kill.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The target node.
  final String nodeId;

  /// The session id or unambiguous prefix to kill.
  final String sessionRef;

  /// Creates a detached-session kill request.
  const DetachedSessionKillRequest({
    required this.requestId,
    required this.nodeId,
    required this.sessionRef,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'nodeId': nodeId,
    'sessionRef': sessionRef,
  };

  /// Decodes a [DetachedSessionKillRequest].
  static DetachedSessionKillRequest fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => DetachedSessionKillRequest(
    requestId: Json.requireString(d, 'requestId'),
    nodeId: Json.requireString(d, 'nodeId'),
    sessionRef: Json.requireString(d, 'sessionRef'),
  );
}

/// Hub → Node: terminate the [principal]'s detached session [sessionRef].
final class NodeDetachedSessionKillRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.sessions.kill.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The owner whose session is killed.
  final String principal;

  /// The session id or unambiguous prefix to kill.
  final String sessionRef;

  /// Creates a node detached-session kill request.
  const NodeDetachedSessionKillRequest({
    required this.requestId,
    required this.principal,
    required this.sessionRef,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'principal': principal,
    'sessionRef': sessionRef,
  };

  /// Decodes a [NodeDetachedSessionKillRequest].
  static NodeDetachedSessionKillRequest fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeDetachedSessionKillRequest(
    requestId: Json.requireString(d, 'requestId'),
    principal: Json.requireString(d, 'principal'),
    sessionRef: Json.requireString(d, 'sessionRef'),
  );
}

/// Node → Hub: the result of a detached-session kill. Correlated by [requestId].
final class NodeDetachedSessionKillResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.sessions.kill.response';

  /// The correlation id from the request.
  final String requestId;

  /// Whether a session was found, owned by the caller, and terminated.
  final bool ok;

  /// A human-readable result/error message.
  final String message;

  /// Creates a node detached-session kill response.
  const NodeDetachedSessionKillResponse({
    required this.requestId,
    required this.ok,
    this.message = '',
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'ok': ok,
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes a [NodeDetachedSessionKillResponse].
  static NodeDetachedSessionKillResponse fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeDetachedSessionKillResponse(
    requestId: Json.requireString(d, 'requestId'),
    ok: Json.optBool(d, 'ok'),
    message: Json.optString(d, 'message') ?? '',
  );
}

/// Hub → Client: the result of a detached-session kill. Correlated by
/// [requestId].
final class DetachedSessionKillResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'sessions.kill.response';

  /// The correlation id from the request.
  final String requestId;

  /// Whether the session was terminated.
  final bool ok;

  /// A human-readable result/error message.
  final String message;

  /// Creates a detached-session kill response.
  const DetachedSessionKillResponse({
    required this.requestId,
    required this.ok,
    this.message = '',
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'ok': ok,
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes a [DetachedSessionKillResponse].
  static DetachedSessionKillResponse fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => DetachedSessionKillResponse(
    requestId: Json.requireString(d, 'requestId'),
    ok: Json.optBool(d, 'ok'),
    message: Json.optString(d, 'message') ?? '',
  );
}

/// Client → Hub: detach an *active* (attached) session on [nodeId] from another
/// connection — e.g. when a full-screen program owns the original terminal.
/// [sessionRef] is an id/short-id/prefix, or empty to target the caller's sole
/// active session. Correlated by [requestId].
final class ActiveSessionDetachRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'sessions.detach.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The target node.
  final String nodeId;

  /// The active session id/prefix to detach, or empty for the sole session.
  final String sessionRef;

  /// Seconds until the resulting detached session expires, or `null`.
  final int? timeoutSeconds;

  /// Creates an active-session detach request.
  const ActiveSessionDetachRequest({
    required this.requestId,
    required this.nodeId,
    this.sessionRef = '',
    this.timeoutSeconds,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'nodeId': nodeId,
    if (sessionRef.isNotEmpty) 'sessionRef': sessionRef,
    if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
  };

  /// Decodes an [ActiveSessionDetachRequest].
  static ActiveSessionDetachRequest fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => ActiveSessionDetachRequest(
    requestId: Json.requireString(d, 'requestId'),
    nodeId: Json.requireString(d, 'nodeId'),
    sessionRef: Json.optString(d, 'sessionRef') ?? '',
    timeoutSeconds: Json.optInt(d, 'timeoutSeconds'),
  );
}

/// Hub → Node: detach the [principal]'s active session [sessionRef].
final class NodeActiveSessionDetach extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.sessions.detach.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The owner whose active session is detached.
  final String principal;

  /// The active session id/prefix to detach, or empty for the sole session.
  final String sessionRef;

  /// Seconds until the resulting detached session expires, or `null`.
  final int? timeoutSeconds;

  /// Creates a node active-session detach request.
  const NodeActiveSessionDetach({
    required this.requestId,
    required this.principal,
    this.sessionRef = '',
    this.timeoutSeconds,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'principal': principal,
    if (sessionRef.isNotEmpty) 'sessionRef': sessionRef,
    if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
  };

  /// Decodes a [NodeActiveSessionDetach].
  static NodeActiveSessionDetach fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeActiveSessionDetach(
    requestId: Json.requireString(d, 'requestId'),
    principal: Json.requireString(d, 'principal'),
    sessionRef: Json.optString(d, 'sessionRef') ?? '',
    timeoutSeconds: Json.optInt(d, 'timeoutSeconds'),
  );
}

/// Node → Hub: the result of an active-session detach. Correlated by [requestId].
final class NodeActiveSessionDetachResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.sessions.detach.response';

  /// The correlation id from the request.
  final String requestId;

  /// Whether an owned active session was found and detached.
  final bool ok;

  /// The short handle of the detached session (empty on failure).
  final String shortId;

  /// A human-readable result/error message.
  final String message;

  /// Creates a node active-session detach response.
  const NodeActiveSessionDetachResponse({
    required this.requestId,
    required this.ok,
    this.shortId = '',
    this.message = '',
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'ok': ok,
    if (shortId.isNotEmpty) 'shortId': shortId,
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes a [NodeActiveSessionDetachResponse].
  static NodeActiveSessionDetachResponse fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeActiveSessionDetachResponse(
    requestId: Json.requireString(d, 'requestId'),
    ok: Json.optBool(d, 'ok'),
    shortId: Json.optString(d, 'shortId') ?? '',
    message: Json.optString(d, 'message') ?? '',
  );
}

/// Hub → Client: the result of an active-session detach. Correlated by
/// [requestId].
final class ActiveSessionDetachResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'sessions.detach.response';

  /// The correlation id from the request.
  final String requestId;

  /// Whether the session was detached.
  final bool ok;

  /// The short handle of the detached session (empty on failure).
  final String shortId;

  /// A human-readable result/error message.
  final String message;

  /// Creates an active-session detach response.
  const ActiveSessionDetachResponse({
    required this.requestId,
    required this.ok,
    this.shortId = '',
    this.message = '',
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'ok': ok,
    if (shortId.isNotEmpty) 'shortId': shortId,
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes an [ActiveSessionDetachResponse].
  static ActiveSessionDetachResponse fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => ActiveSessionDetachResponse(
    requestId: Json.requireString(d, 'requestId'),
    ok: Json.optBool(d, 'ok'),
    shortId: Json.optString(d, 'shortId') ?? '',
    message: Json.optString(d, 'message') ?? '',
  );
}

/// Client → Hub: fetch the current screen snapshot of the caller's session
/// [sessionRef] (active or detached) on [nodeId], without attaching to it.
/// Correlated by [requestId].
final class SessionScreenRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'sessions.screen.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The target node.
  final String nodeId;

  /// The session id or unambiguous prefix to peek at.
  final String sessionRef;

  /// Creates a session-screen request.
  const SessionScreenRequest({
    required this.requestId,
    required this.nodeId,
    required this.sessionRef,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'nodeId': nodeId,
    'sessionRef': sessionRef,
  };

  /// Decodes a [SessionScreenRequest].
  static SessionScreenRequest fromJson(int? channel, Map<String, dynamic> d) =>
      SessionScreenRequest(
        requestId: Json.requireString(d, 'requestId'),
        nodeId: Json.requireString(d, 'nodeId'),
        sessionRef: Json.requireString(d, 'sessionRef'),
      );
}

/// Hub → Node: fetch the current screen snapshot of the [principal]'s session
/// [sessionRef]. Correlated by [requestId].
final class NodeSessionScreenRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.sessions.screen.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The owner whose session is peeked at.
  final String principal;

  /// The session id or unambiguous prefix to peek at.
  final String sessionRef;

  /// Creates a node session-screen request.
  const NodeSessionScreenRequest({
    required this.requestId,
    required this.principal,
    required this.sessionRef,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'principal': principal,
    'sessionRef': sessionRef,
  };

  /// Decodes a [NodeSessionScreenRequest].
  static NodeSessionScreenRequest fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeSessionScreenRequest(
    requestId: Json.requireString(d, 'requestId'),
    principal: Json.requireString(d, 'principal'),
    sessionRef: Json.requireString(d, 'sessionRef'),
  );
}

/// Node → Hub: the current screen snapshot of a session. The replayable bytes
/// (the same a resume would paint) are base64-encoded in [screenBase64].
/// Correlated by [requestId].
final class NodeSessionScreenResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.sessions.screen.response';

  /// The correlation id from the request.
  final String requestId;

  /// Whether a session was found, owned by the caller, and captured.
  final bool ok;

  /// A human-readable result/error message.
  final String message;

  /// The captured screen bytes, base64-encoded (empty on failure).
  final String screenBase64;

  /// Whether the capture ends inside the alternate screen (full-screen program).
  final bool altScreen;

  /// Creates a node session-screen response.
  const NodeSessionScreenResponse({
    required this.requestId,
    required this.ok,
    this.message = '',
    this.screenBase64 = '',
    this.altScreen = false,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'ok': ok,
    if (message.isNotEmpty) 'message': message,
    if (screenBase64.isNotEmpty) 'screen': screenBase64,
    if (altScreen) 'altScreen': altScreen,
  };

  /// Decodes a [NodeSessionScreenResponse].
  static NodeSessionScreenResponse fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeSessionScreenResponse(
    requestId: Json.requireString(d, 'requestId'),
    ok: Json.optBool(d, 'ok'),
    message: Json.optString(d, 'message') ?? '',
    screenBase64: Json.optString(d, 'screen') ?? '',
    altScreen: Json.optBool(d, 'altScreen'),
  );
}

/// Hub → Client: the current screen snapshot of a session. Correlated by
/// [requestId].
final class SessionScreenResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'sessions.screen.response';

  /// The correlation id from the request.
  final String requestId;

  /// Whether the snapshot was captured.
  final bool ok;

  /// A human-readable result/error message.
  final String message;

  /// The captured screen bytes, base64-encoded (empty on failure).
  final String screenBase64;

  /// Whether the capture ends inside the alternate screen (full-screen program).
  final bool altScreen;

  /// Creates a session-screen response.
  const SessionScreenResponse({
    required this.requestId,
    required this.ok,
    this.message = '',
    this.screenBase64 = '',
    this.altScreen = false,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'ok': ok,
    if (message.isNotEmpty) 'message': message,
    if (screenBase64.isNotEmpty) 'screen': screenBase64,
    if (altScreen) 'altScreen': altScreen,
  };

  /// Decodes a [SessionScreenResponse].
  static SessionScreenResponse fromJson(int? channel, Map<String, dynamic> d) =>
      SessionScreenResponse(
        requestId: Json.requireString(d, 'requestId'),
        ok: Json.optBool(d, 'ok'),
        message: Json.optString(d, 'message') ?? '',
        screenBase64: Json.optString(d, 'screen') ?? '',
        altScreen: Json.optBool(d, 'altScreen'),
      );
}

List<DetachedSessionInfo> _decodeSessions(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => DetachedSessionInfo.fromJson(e.cast<String, dynamic>()))
      .toList();
}

// ---------------------------------------------------------------------------
// Tunnels (TCP port forwarding)
// ---------------------------------------------------------------------------

/// Client → Hub: open a tunnel that exposes `targetHost:targetPort` (reachable
/// by [nodeId], or the requesting client's own machine when [nodeId] is the
/// `@local` sentinel) on a public Hub port. When [publicPort] is set the Hub
/// validates it against its configured range; otherwise the Hub allocates a
/// free port in range. Correlated by [requestId].
final class TunnelOpenRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'tunnel.open.request';

  /// The sentinel [nodeId] selecting the requesting client's own machine.
  static const String localNode = '@local';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The exposer node id, or [localNode] for the requesting client's machine.
  final String nodeId;

  /// The internal host the exposer dials.
  final String targetHost;

  /// The internal TCP port the exposer dials.
  final int targetPort;

  /// A specific public port to request (validated against the Hub's range), or
  /// `null` to let the Hub allocate one in range.
  final int? publicPort;

  /// Whether the public port should terminate TLS (HTTPS). When true the Hub
  /// must have a tunnel TLS certificate configured, otherwise the open is
  /// rejected. The Hub→exposer→target hops stay plaintext regardless.
  final bool secure;

  /// Creates a tunnel-open request.
  const TunnelOpenRequest({
    required this.requestId,
    required this.nodeId,
    required this.targetPort,
    this.targetHost = 'localhost',
    this.publicPort,
    this.secure = false,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'nodeId': nodeId,
    'targetHost': targetHost,
    'targetPort': targetPort,
    if (publicPort != null) 'publicPort': publicPort,
    if (secure) 'secure': true,
  };

  /// Decodes a [TunnelOpenRequest].
  static TunnelOpenRequest fromJson(int? channel, Map<String, dynamic> d) =>
      TunnelOpenRequest(
        requestId: Json.requireString(d, 'requestId'),
        nodeId: Json.requireString(d, 'nodeId'),
        targetHost: Json.optString(d, 'targetHost') ?? 'localhost',
        targetPort: Json.requireInt(d, 'targetPort'),
        publicPort: Json.optInt(d, 'publicPort'),
        secure: Json.optBool(d, 'secure'),
      );
}

/// Hub → Client: the tunnel is open and listening. Correlated by [requestId].
final class TunnelOpened extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'tunnel.opened';

  /// The correlation id from the request.
  final String requestId;

  /// The minted tunnel id.
  final String tunnelId;

  /// The host the Hub advertises for the public listener (may be empty/wildcard;
  /// clients substitute the Hub's own hostname).
  final String publicHost;

  /// The public TCP port the Hub is listening on.
  final int publicPort;

  /// Whether the public port terminates TLS (HTTPS).
  final bool secure;

  /// Creates a tunnel-opened.
  const TunnelOpened({
    required this.requestId,
    required this.tunnelId,
    required this.publicHost,
    required this.publicPort,
    this.secure = false,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'tunnelId': tunnelId,
    'publicHost': publicHost,
    'publicPort': publicPort,
    if (secure) 'secure': true,
  };

  /// Decodes a [TunnelOpened].
  static TunnelOpened fromJson(int? channel, Map<String, dynamic> d) =>
      TunnelOpened(
        requestId: Json.requireString(d, 'requestId'),
        tunnelId: Json.requireString(d, 'tunnelId'),
        publicHost: Json.optString(d, 'publicHost') ?? '',
        publicPort: Json.requireInt(d, 'publicPort'),
        secure: Json.optBool(d, 'secure'),
      );
}

/// Hub → Client: the tunnel was refused. Correlated by [requestId].
final class TunnelRejected extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'tunnel.rejected';

  /// The correlation id from the request.
  final String requestId;

  /// A machine reason (`tunnel_disabled`, `port_out_of_range`, `port_in_use`,
  /// `not_authorized`, `unknown_node`, `node_offline`, `unsupported`,
  /// `secure_unavailable`).
  final String reason;

  /// A human-readable message.
  final String message;

  /// Creates a tunnel-rejected.
  const TunnelRejected({
    required this.requestId,
    required this.reason,
    required this.message,
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'reason': reason,
    'message': message,
  };

  /// Decodes a [TunnelRejected].
  static TunnelRejected fromJson(int? channel, Map<String, dynamic> d) =>
      TunnelRejected(
        requestId: Json.requireString(d, 'requestId'),
        reason: Json.optString(d, 'reason') ?? 'tunnel_rejected',
        message: Json.optString(d, 'message') ?? 'Tunnel rejected',
      );
}

/// Client → Hub: close the caller's tunnel [tunnelRef] (a full id or unambiguous
/// prefix). Correlated by [requestId].
final class TunnelCloseRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'tunnel.close.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// The tunnel id or unambiguous prefix to close.
  final String tunnelRef;

  /// Creates a tunnel-close request.
  const TunnelCloseRequest({required this.requestId, required this.tunnelRef});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'tunnelRef': tunnelRef,
  };

  /// Decodes a [TunnelCloseRequest].
  static TunnelCloseRequest fromJson(int? channel, Map<String, dynamic> d) =>
      TunnelCloseRequest(
        requestId: Json.requireString(d, 'requestId'),
        tunnelRef: Json.requireString(d, 'tunnelRef'),
      );
}

/// Hub → Client: the result of a tunnel close. Correlated by [requestId].
final class TunnelCloseResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'tunnel.close.response';

  /// The correlation id from the request.
  final String requestId;

  /// Whether a tunnel was found, owned by the caller, and closed.
  final bool ok;

  /// A human-readable result/error message.
  final String message;

  /// Creates a tunnel-close response.
  const TunnelCloseResponse({
    required this.requestId,
    required this.ok,
    this.message = '',
  });

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'ok': ok,
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes a [TunnelCloseResponse].
  static TunnelCloseResponse fromJson(int? channel, Map<String, dynamic> d) =>
      TunnelCloseResponse(
        requestId: Json.requireString(d, 'requestId'),
        ok: Json.optBool(d, 'ok'),
        message: Json.optString(d, 'message') ?? '',
      );
}

/// Client → Hub: list the caller's active tunnels. Correlated by [requestId].
final class TunnelListRequest extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'tunnel.list.request';

  /// The correlation id echoed in the response.
  final String requestId;

  /// Creates a tunnel-list request.
  const TunnelListRequest({required this.requestId});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {'requestId': requestId};

  /// Decodes a [TunnelListRequest].
  static TunnelListRequest fromJson(int? channel, Map<String, dynamic> d) =>
      TunnelListRequest(requestId: Json.requireString(d, 'requestId'));
}

/// Hub → Client: the caller's active tunnels. Correlated by [requestId].
final class TunnelListResponse extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'tunnel.list.response';

  /// The correlation id from the request.
  final String requestId;

  /// The caller's active tunnels.
  final List<TunnelInfo> tunnels;

  /// Creates a tunnel-list response.
  const TunnelListResponse({required this.requestId, required this.tunnels});

  @override
  String get type => typeName;

  @override
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'tunnels': tunnels.map((t) => t.toJson()).toList(),
  };

  /// Decodes a [TunnelListResponse].
  static TunnelListResponse fromJson(int? channel, Map<String, dynamic> d) =>
      TunnelListResponse(
        requestId: Json.requireString(d, 'requestId'),
        tunnels: _decodeTunnels(d['tunnels']),
      );
}

/// Hub → exposer (node or client): a public connection arrived; adopt [channel],
/// dial `targetHost:targetPort`, and bridge bytes. Reply with [NodeTunnelConnected]
/// or [NodeTunnelConnectFailed].
final class NodeTunnelConnect extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.tunnel.connect';

  /// The hub-allocated channel id on the exposer's connection.
  final int channel;

  /// The owning tunnel id.
  final String tunnelId;

  /// The internal host to dial.
  final String targetHost;

  /// The internal TCP port to dial.
  final int targetPort;

  /// The authenticated principal that owns the tunnel.
  final String principal;

  /// Creates a node-tunnel-connect.
  const NodeTunnelConnect({
    required this.channel,
    required this.tunnelId,
    required this.targetHost,
    required this.targetPort,
    required this.principal,
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'tunnelId': tunnelId,
    'targetHost': targetHost,
    'targetPort': targetPort,
    'principal': principal,
  };

  /// Decodes a [NodeTunnelConnect].
  static NodeTunnelConnect fromJson(int? channel, Map<String, dynamic> d) =>
      NodeTunnelConnect(
        channel: channel ?? (throw _missingChannel(typeName)),
        tunnelId: Json.requireString(d, 'tunnelId'),
        targetHost: Json.optString(d, 'targetHost') ?? 'localhost',
        targetPort: Json.requireInt(d, 'targetPort'),
        principal: Json.optString(d, 'principal') ?? '',
      );
}

/// Exposer → Hub: the target was dialed; the Hub may relay bytes on [channel].
final class NodeTunnelConnected extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.tunnel.connected';

  /// The channel id from the connect request.
  final int channel;

  /// The owning tunnel id.
  final String tunnelId;

  /// Creates a node-tunnel-connected.
  const NodeTunnelConnected({required this.channel, required this.tunnelId});

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {'tunnelId': tunnelId};

  /// Decodes a [NodeTunnelConnected].
  static NodeTunnelConnected fromJson(int? channel, Map<String, dynamic> d) =>
      NodeTunnelConnected(
        channel: channel ?? (throw _missingChannel(typeName)),
        tunnelId: Json.optString(d, 'tunnelId') ?? '',
      );
}

/// Exposer → Hub: the target dial failed; the Hub closes the public socket.
final class NodeTunnelConnectFailed extends ControlMessage {
  /// The type discriminator.
  static const String typeName = 'node.tunnel.connect.failed';

  /// The channel id from the connect request.
  final int channel;

  /// The owning tunnel id.
  final String tunnelId;

  /// A machine reason (e.g. `dial_failed`, `forbidden`).
  final String reason;

  /// A human-readable message.
  final String message;

  /// Creates a node-tunnel-connect-failed.
  const NodeTunnelConnectFailed({
    required this.channel,
    required this.tunnelId,
    required this.reason,
    this.message = '',
  });

  @override
  String get type => typeName;

  @override
  int? get channelId => channel;

  @override
  Map<String, dynamic> toJson() => {
    'tunnelId': tunnelId,
    'reason': reason,
    if (message.isNotEmpty) 'message': message,
  };

  /// Decodes a [NodeTunnelConnectFailed].
  static NodeTunnelConnectFailed fromJson(
    int? channel,
    Map<String, dynamic> d,
  ) => NodeTunnelConnectFailed(
    channel: channel ?? (throw _missingChannel(typeName)),
    tunnelId: Json.optString(d, 'tunnelId') ?? '',
    reason: Json.optString(d, 'reason') ?? 'dial_failed',
    message: Json.optString(d, 'message') ?? '',
  );
}

List<TunnelInfo> _decodeTunnels(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => TunnelInfo.fromJson(e.cast<String, dynamic>()))
      .toList();
}

FormatException _missingChannel(String type) =>
    FormatException("Control message '$type' requires a channel id");
