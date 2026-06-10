import 'dart:async';
import 'dart:typed_data';

import '../../domain/backend/shell_session.dart';
import '../../domain/entities/detached_session_info.dart';
import '../../domain/entities/session.dart';
import '../../domain/value_objects/node_id.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/screen_replay_buffer.dart';

/// Owns the *single* subscription to a shell's `stdout`/`stderr` for the whole
/// life of the shell, forwarding bytes to a swappable sink.
///
/// A node shell's output streams are single-subscription (OS pipes), so they
/// can be listened to only once. Detach/resume must therefore not cancel and
/// re-listen them; instead the pump subscribes once and the consumer swaps
/// [onStdout]/[onStderr] between the live channel (attached) and nothing
/// (detached). The hand-off is lossless as long as the sink is repointed in the
/// same synchronous turn.
///
/// Independently of the swappable sink, every byte is *always* fed into
/// [screen] — a continuous, alt-screen-aware capture of recent output — so a
/// resume can repaint the current screen (including a full-screen program drawn
/// before the client detached).
class ShellOutputPump {
  /// The shell whose output this pump forwards.
  final ShellSession shell;

  /// Current stdout sink, or `null` to drop bytes.
  void Function(Uint8List data)? onStdout;

  /// Current stderr sink, or `null` to drop bytes.
  void Function(Uint8List data)? onStderr;

  /// Continuous, alt-screen-aware capture used to repaint on resume.
  final ScreenReplayBuffer screen = ScreenReplayBuffer();

  /// Completes when the shell's stdout stream ends (the process exited).
  final Completer<void> stdoutDone = Completer<void>();

  /// Completes when the shell's stderr stream ends.
  final Completer<void> stderrDone = Completer<void>();

  late final StreamSubscription<Uint8List> _outSub;
  late final StreamSubscription<Uint8List> _errSub;
  bool _disposed = false;

  /// Subscribes once to [shell]'s output streams.
  ShellOutputPump(this.shell) {
    _outSub = shell.stdout.listen(
      (d) {
        screen.add(d);
        onStdout?.call(d);
      },
      onDone: () => _complete(stdoutDone),
      cancelOnError: false,
    );
    _errSub = shell.stderr.listen(
      (d) {
        screen.add(d);
        onStderr?.call(d);
      },
      onDone: () => _complete(stderrDone),
      cancelOnError: false,
    );
  }

  /// Cancels the underlying subscriptions. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    onStdout = null;
    onStderr = null;
    await _outSub.cancel();
    await _errSub.cancel();
  }

  static void _complete(Completer<void> c) {
    if (!c.isCompleted) c.complete();
  }
}

/// A live but detached session held in a node's memory: the PTY, shell and
/// child processes keep running while no client is attached.
///
/// While detached the shell's output is drained into [outputBuffer] (a bounded
/// ring buffer) so nothing is lost and the pipes never block; on resume the
/// retained tail is replayed to the new client. The session owns no channel
/// while detached — a fresh channel is bound on resume.
class DetachedNodeSession {
  /// The full, cryptographically-secure session id.
  final String sessionId;

  /// A short, display-only handle derived from [sessionId].
  final String shortId;

  /// The authenticated principal that owns the session.
  final String ownerPrincipal;

  /// The node hosting the session.
  final NodeId nodeId;

  /// The session mode (always [SessionMode.shell] for detachable sessions).
  final SessionMode mode;

  /// When the session was first opened.
  final DateTime createdAt;

  /// When the session was most recently detached.
  final DateTime detachedAt;

  /// When the session expires and is cleaned up, or `null` for indefinite.
  final DateTime? expiresAt;

  /// The persistent output pump over the still-running shell. Its
  /// [ShellOutputPump.screen] holds the capture replayed on resume.
  final ShellOutputPump pump;

  /// Lowercase, hyphen-free form of [sessionId] used for prefix matching.
  final String _compactId;

  /// The still-running shell/PTY.
  ShellSession get shell => pump.shell;

  /// Creates a detached node session. The live sink of [pump] is expected to be
  /// dropped in the same synchronous turn the session detaches; output is still
  /// captured into [ShellOutputPump.screen] for the resume repaint.
  DetachedNodeSession({
    required this.sessionId,
    required this.shortId,
    required this.ownerPrincipal,
    required this.nodeId,
    required this.mode,
    required this.createdAt,
    required this.detachedAt,
    required this.pump,
    this.expiresAt,
  }) : _compactId = sessionId.replaceAll('-', '').toLowerCase();

  /// Whether [ref] (an id, short id or prefix, hyphens ignored) names this
  /// session.
  bool matches(String ref) {
    final r = ref.replaceAll('-', '').toLowerCase();
    return r.isNotEmpty && _compactId.startsWith(r);
  }

  /// Terminates the shell/PTY and releases the output pump.
  Future<void> kill() async {
    await pump.dispose();
    await shell.kill();
  }

  /// A wire-safe view of this session.
  DetachedSessionInfo toInfo() => DetachedSessionInfo(
    sessionId: sessionId,
    shortId: shortId,
    nodeId: nodeId.value,
    ownerUserId: ownerPrincipal,
    mode: mode,
    createdAt: createdAt,
    detachedAt: detachedAt,
    expiresAt: expiresAt,
    state: SessionState.detached,
  );
}

/// The outcome of resolving a user-supplied session reference.
enum SessionRefStatus {
  /// Exactly one owned session matched.
  found,

  /// No owned session matched.
  notFound,

  /// More than one owned session matched the prefix.
  ambiguous,
}

/// The result of [DetachedSessionRegistry.resolveRef].
class SessionRefResult {
  /// The match status.
  final SessionRefStatus status;

  /// The resolved session when [status] is [SessionRefStatus.found].
  final DetachedNodeSession? session;

  const SessionRefResult(this.status, [this.session]);
}

/// A node's in-memory registry of detached sessions, keyed by full session id.
///
/// This is the authoritative, RAM-only store of detached sessions — never
/// written to disk and lost on node restart by design. All ownership checks
/// (list/resume/kill) are enforced here against the authenticated principal.
class DetachedSessionRegistry {
  final Map<String, DetachedNodeSession> _byId = {};
  final Clock _clock;

  /// Creates a registry using [clock] for the expiry scan.
  DetachedSessionRegistry({Clock clock = const SystemClock()}) : _clock = clock;

  /// The number of detached sessions held.
  int get length => _byId.length;

  /// Registers [session] and arranges for it to be removed (and its pump
  /// released) if the shell exits on its own while detached.
  void add(DetachedNodeSession session) {
    _byId[session.sessionId] = session;
    unawaited(
      session.shell.exitCode
          .then((_) {
            if (identical(_byId[session.sessionId], session)) {
              _byId.remove(session.sessionId);
              unawaited(session.pump.dispose());
            }
          })
          .catchError((_) {}),
    );
  }

  /// Removes and returns the session with [sessionId], or `null` if absent.
  DetachedNodeSession? removeById(String sessionId) => _byId.remove(sessionId);

  /// The sessions owned by [principal].
  List<DetachedNodeSession> listForOwner(String principal) => _byId.values
      .where((s) => s.ownerPrincipal == principal)
      .toList(growable: false);

  /// Resolves [ref] (an id, short id or unambiguous prefix) within the sessions
  /// owned by [principal]. Other users' sessions are never considered, so a ref
  /// that only matches another owner reports [SessionRefStatus.notFound] — the
  /// existence of another user's session is never revealed.
  SessionRefResult resolveRef(String principal, String ref) {
    final matches = listForOwner(
      principal,
    ).where((s) => s.matches(ref)).toList();
    if (matches.isEmpty) {
      return const SessionRefResult(SessionRefStatus.notFound);
    }
    if (matches.length > 1) {
      return const SessionRefResult(SessionRefStatus.ambiguous);
    }
    return SessionRefResult(SessionRefStatus.found, matches.first);
  }

  /// Terminates and removes every session whose [DetachedNodeSession.expiresAt]
  /// is in the past relative to [now] (defaults to the registry clock). Returns
  /// the number removed.
  Future<int> killExpired([DateTime? now]) async {
    final at = now ?? _clock.now();
    final expired = _byId.values
        .where((s) => s.expiresAt != null && at.isAfter(s.expiresAt!))
        .toList();
    for (final s in expired) {
      _byId.remove(s.sessionId);
      await s.kill();
    }
    return expired.length;
  }

  /// Terminates and removes all sessions (node shutdown).
  Future<void> disposeAll() async {
    final all = _byId.values.toList();
    _byId.clear();
    for (final s in all) {
      await s.kill();
    }
  }
}
