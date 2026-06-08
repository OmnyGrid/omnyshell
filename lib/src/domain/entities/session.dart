import 'package:meta/meta.dart';

import '../value_objects/node_id.dart';
import '../value_objects/principal_id.dart';
import '../value_objects/session_id.dart';

/// How a session runs on the node.
enum SessionMode {
  /// Run a single command to completion, streaming its output.
  exec,

  /// Start a long-lived interactive shell with bidirectional streaming.
  shell,

  /// Move a file/directory between client and node over a framed, compressed,
  /// resumable byte stream (no process; handled by the node's transfer service).
  transfer,

  /// Serve an OmnyDrive mount over a long-lived request/response channel (no
  /// process; handled by the node's drive service). The client drives the
  /// OmnyDrive sync engine and issues content/git RPCs against a node path.
  drive;

  /// Parses a wire value, defaulting to [SessionMode.exec] for unknown input.
  static SessionMode parse(String value) => switch (value) {
    'shell' => SessionMode.shell,
    'transfer' => SessionMode.transfer,
    'drive' => SessionMode.drive,
    _ => SessionMode.exec,
  };
}

/// Lifecycle state of a session as tracked by the Hub.
enum SessionState {
  /// The open handshake is in flight.
  opening,

  /// The session is live and relaying data.
  open,

  /// A close has been initiated; teardown is in progress.
  closing,

  /// The session has fully closed.
  closed,
}

/// A domain view of a brokered session: who opened it, on which node, in what
/// mode, and its current state and exit code.
@immutable
class Session {
  /// The session's unique id.
  final SessionId id;

  /// The node the session runs on.
  final NodeId nodeId;

  /// The principal that opened the session.
  final PrincipalId principal;

  /// Whether the session is an exec or an interactive shell.
  final SessionMode mode;

  /// The session's current lifecycle state.
  final SessionState state;

  /// The process exit code, once the session has finished (else `null`).
  final int? exitCode;

  /// When the session was opened.
  final DateTime openedAt;

  /// Creates a session view.
  const Session({
    required this.id,
    required this.nodeId,
    required this.principal,
    required this.mode,
    required this.state,
    required this.openedAt,
    this.exitCode,
  });

  /// Returns a copy with selected fields replaced.
  Session copyWith({SessionState? state, int? exitCode}) => Session(
    id: id,
    nodeId: nodeId,
    principal: principal,
    mode: mode,
    state: state ?? this.state,
    openedAt: openedAt,
    exitCode: exitCode ?? this.exitCode,
  );
}
