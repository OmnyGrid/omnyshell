import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import 'session.dart';

/// A user-facing view of a detached session living in a node's in-memory
/// registry, as returned by the list API and relayed through the Hub.
///
/// It carries no live PTY/shell handles — only metadata safe to cross the wire.
/// Ownership is identified by [ownerUserId] (the authenticated principal id);
/// the node filters listings by owner before they ever leave the node.
@immutable
class DetachedSessionInfo {
  /// The full, cryptographically-secure session id.
  final String sessionId;

  /// A short, display-only handle derived from [sessionId]. Resume/kill accept
  /// any unambiguous prefix of [sessionId] (the short id being one such).
  final String shortId;

  /// The node that owns the session.
  final String nodeId;

  /// The authenticated principal that owns the session.
  final String ownerUserId;

  /// The session mode (always `shell` for detachable interactive sessions).
  final SessionMode mode;

  /// When the session was first opened.
  final DateTime createdAt;

  /// When the session was detached, or `null` if it is still attached.
  final DateTime? detachedAt;

  /// When the session expires and is cleaned up, or `null` for indefinite.
  final DateTime? expiresAt;

  /// The session lifecycle state (typically [SessionState.detached]).
  final SessionState state;

  /// The current foreground command running in the session, or `null` when the
  /// shell is at its prompt or it could not be determined.
  final String? currentCommand;

  /// The session's current working directory, or `null` when it could not be
  /// determined.
  final String? currentCwd;

  /// Creates a detached-session view.
  const DetachedSessionInfo({
    required this.sessionId,
    required this.shortId,
    required this.nodeId,
    required this.ownerUserId,
    required this.mode,
    required this.createdAt,
    required this.state,
    this.detachedAt,
    this.expiresAt,
    this.currentCommand,
    this.currentCwd,
  });

  /// A copy of this info with the live [currentCommand]/[currentCwd] filled in.
  DetachedSessionInfo withLiveState({String? command, String? cwd}) =>
      DetachedSessionInfo(
        sessionId: sessionId,
        shortId: shortId,
        nodeId: nodeId,
        ownerUserId: ownerUserId,
        mode: mode,
        createdAt: createdAt,
        state: state,
        detachedAt: detachedAt,
        expiresAt: expiresAt,
        currentCommand: command,
        currentCwd: cwd,
      );

  /// Encodes this info to a JSON map.
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'shortId': shortId,
    'nodeId': nodeId,
    'ownerUserId': ownerUserId,
    'mode': mode.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (detachedAt != null) 'detachedAt': detachedAt!.toUtc().toIso8601String(),
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    'state': state.name,
    if (currentCommand != null) 'currentCommand': currentCommand,
    if (currentCwd != null) 'currentCwd': currentCwd,
  };

  /// Decodes a [DetachedSessionInfo] from a JSON map.
  static DetachedSessionInfo fromJson(Map<String, dynamic> d) =>
      DetachedSessionInfo(
        sessionId: Json.requireString(d, 'sessionId'),
        shortId: Json.requireString(d, 'shortId'),
        nodeId: Json.requireString(d, 'nodeId'),
        ownerUserId: Json.requireString(d, 'ownerUserId'),
        mode: SessionMode.parse(Json.optString(d, 'mode') ?? 'shell'),
        createdAt: Json.requireTimestamp(d, 'createdAt'),
        detachedAt: Json.optTimestamp(d, 'detachedAt'),
        expiresAt: Json.optTimestamp(d, 'expiresAt'),
        state: SessionState.parse(Json.optString(d, 'state') ?? 'detached'),
        currentCommand: Json.optString(d, 'currentCommand'),
        currentCwd: Json.optString(d, 'currentCwd'),
      );
}
