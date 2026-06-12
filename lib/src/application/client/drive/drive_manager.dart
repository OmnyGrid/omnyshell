import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnydrive/omnydrive.dart' hide Clock, SystemClock;
import 'package:path/path.dart' as p;

import '../../../domain/entities/session.dart';
import '../../drive/drive_wire.dart';
import '../client_runtime.dart';
import '../remote_session.dart';
import 'channel_content_source.dart';
import 'drive_rpc_client.dart';
import 'mount_store.dart';

/// The outcome of a synchronization, surfaced to the CLI.
class SyncOutcome {
  /// The resulting mount record (with updated state).
  final MountRecord record;

  /// The direction actually run, or `null` for a no-op.
  final SyncDirection? direction;

  /// Number of changes applied.
  final int applied;

  /// For git pushes, the branch the changes were published to.
  final String? publishedBranch;

  /// Set when the sync detected a conflict instead of applying.
  final Conflict? conflict;

  /// Creates a sync outcome.
  SyncOutcome({
    required this.record,
    this.direction,
    this.applied = 0,
    this.publishedBranch,
    this.conflict,
  });

  /// Whether the sync ended in a conflict.
  bool get isConflict => conflict != null;
}

/// Sink for live sync progress, fed omnydrive [ProgressEvent]s as each file is
/// uploaded/downloaded (directory mounts) or as a git push/clone advances.
typedef DriveProgress = void Function(ProgressEvent event);

/// Orchestrates OmnyDrive mounts over OmnyShell drive sessions.
///
/// The client is the active side of a mount: it runs OmnyDrive's directory
/// synchronizer (for `dir` mounts) against a [ChannelContentSource] that reaches
/// the node, or issues git RPCs the node executes (for `git` mounts). Mount
/// state is persisted in a [MountStore]; the Hub and Node need no mount registry.
class DriveManager {
  /// The connected, authenticated client.
  final ClientRuntime client;

  /// The persisted mount registry.
  final MountStore store;

  /// Creates a manager over [client] and [store].
  DriveManager(this.client, this.store);

  /// Loads the mount store and returns a manager bound to [client]. [home]
  /// overrides the state directory (tests use an isolated one).
  static Future<DriveManager> open(
    ClientRuntime client, {
    String? home,
  }) async => DriveManager(client, await MountStore.load(home: home));

  /// All known mounts, ordered by id.
  List<MountRecord> list() {
    final all = store.mounts.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return all;
  }

  /// The mount with [id], or `null`.
  MountRecord? get(String id) => store.mounts[id];

  /// Looks up [id] or throws a [DriveException].
  MountRecord require(String id) {
    final r = store.mounts[id];
    if (r == null) throw DriveException('no such mount: $id');
    return r;
  }

  // --- Mounting --------------------------------------------------------------

  /// Finds a directory mount that [run]/`exec --mount` can reuse for [localDir]
  /// on [nodeId], or `null` if none.
  ///
  /// Only read-write `dir` mounts for the same normalized local path qualify.
  /// When [remotePath] is given (an explicit `--mount-path`), the node path must
  /// also match; when it is `null` (an ephemeral run), only a previously
  /// *ephemeral* mount qualifies (its recorded path is reused). The most
  /// recently mounted match wins.
  MountRecord? findReusableDirMount({
    required String nodeId,
    required String localDir,
    String? remotePath,
  }) {
    final localAbs = p.normalize(Directory(localDir).absolute.path);
    final matches = store.mounts.values.where((r) {
      if (r.isGit || r.kind != 'dir' || !r.readWrite) return false;
      if (r.nodeId != nodeId || r.localPath == null) return false;
      if (p.normalize(r.localPath!) != localAbs) return false;
      return remotePath != null ? r.remotePath == remotePath : r.ephemeral;
    }).toList()..sort((a, b) => b.mountedAt.compareTo(a.mountedAt));
    return matches.isEmpty ? null : matches.first;
  }

  /// Mounts a local directory onto [remotePath] of [nodeId].
  Future<MountRecord> mountDirectory({
    required String localDir,
    required String nodeId,
    required String remotePath,
    String? name,
    bool readWrite = false,
    bool initialSync = true,
    bool ephemeral = false,
    PathFilter? filter,
    DriveProgress? onProgress,
  }) async {
    final dir = Directory(localDir);
    if (!await dir.exists()) {
      throw DriveException('local directory not found: $localDir');
    }
    // Normalize so a path like "." or "./" (whose absolute form ends in "/.")
    // yields a clean root and a real directory name — otherwise the derived
    // mount name would be "." and produce an invalid drive id.
    final localAbs = p.normalize(dir.absolute.path);
    final mountName = name ?? _basename(localAbs);
    final endpoint = _endpointId(nodeId);
    final driveId = DriveId.scoped(endpoint: endpoint, name: mountName);
    final id = _mountId(nodeId, mountName);

    var record = MountRecord(
      id: id,
      nodeId: nodeId,
      name: mountName,
      kind: 'dir',
      remotePath: remotePath,
      localPath: localAbs,
      readWrite: readWrite,
      ephemeral: ephemeral,
      driveId: driveId.value,
      mountedAt: DateTime.now(),
      syncState: SyncState(baselineRef: _emptyDirRef, status: SyncStatus.clean),
      filter: filter,
    );

    record = await _withSession(record, (rpc) async {
      // Anchor the baseline at the node's current content before the first push.
      final originRef = (await ChannelContentSource(rpc).manifest()).hash();
      var r = record.copyWith(
        syncState: SyncState(baselineRef: originRef, status: SyncStatus.clean),
      );
      if (initialSync) {
        r = (await _syncDirectory(
          r,
          rpc,
          SyncDirection.push,
          onProgress: onProgress,
        )).record;
      }
      return r;
    });

    store.mounts[id] = record;
    await store.save();
    return record;
  }

  /// Mounts a git repository onto [remotePath] of [nodeId]. The node clones the
  /// repo, so [url] must be reachable from the node.
  Future<MountRecord> mountGit({
    required String url,
    required String nodeId,
    required String remotePath,
    String? name,
    String? branch,
    int? depth,
    bool readWrite = false,
    DriveProgress? onProgress,
  }) async {
    final mountName = name ?? _gitName(url);
    final endpoint = _endpointId(nodeId);
    final driveId = DriveId.scoped(endpoint: endpoint, name: mountName);
    final id = _mountId(nodeId, mountName);

    var record = MountRecord(
      id: id,
      nodeId: nodeId,
      name: mountName,
      kind: 'git',
      remotePath: remotePath,
      gitUrl: url,
      gitBranch: branch,
      readWrite: readWrite,
      driveId: driveId.value,
      mountedAt: DateTime.now(),
      syncState: SyncState(
        baselineRef: SyncRef.git('0'),
        status: SyncStatus.clean,
      ),
    );

    record = await _withSession(record, (rpc) async {
      _emit(onProgress, ProgressPhase.transferring, 'cloning $url');
      final head = await rpc.gitClone(url, branch: branch, depth: depth);
      _emit(onProgress, ProgressPhase.done, 'cloned');
      return record.copyWith(
        syncState: SyncState(
          baselineRef: SyncRef.git(head),
          currentRef: SyncRef.git(head),
          status: SyncStatus.clean,
          lastSyncedAt: DateTime.now(),
        ),
      );
    });

    store.mounts[id] = record;
    await store.save();
    return record;
  }

  // --- Syncing ---------------------------------------------------------------

  /// Synchronizes [mountId]. With no [direction], picks one automatically:
  /// read-only mounts always push; read-write mounts push, pull or no-op based
  /// on which side changed (a two-sided change surfaces a conflict).
  Future<SyncOutcome> sync(
    String mountId, {
    SyncDirection? direction,
    DriveProgress? onProgress,
  }) async {
    final record = require(mountId);
    final outcome = await _withSession(record, (rpc) async {
      if (record.isGit) {
        return _syncGit(record, rpc, direction, onProgress: onProgress);
      }
      final dir = direction ?? await _autoDirection(record, rpc);
      if (dir == null) {
        return SyncOutcome(record: record); // already clean
      }
      return _syncDirectory(record, rpc, dir, onProgress: onProgress);
    });
    store.mounts[mountId] = outcome.record;
    await store.save();
    return outcome;
  }

  Future<SyncDirection?> _autoDirection(
    MountRecord record,
    DriveRpcClient rpc,
  ) async {
    if (!record.readWrite) return SyncDirection.push;
    final baseline = record.syncState.baselineRef;
    final localHash = (await LocalContentSource(
      record.localPath!,
      filter: record.filter.isEmpty ? null : record.filter,
    ).manifest()).hash();
    final originHash = (await ChannelContentSource(rpc).manifest()).hash();
    if (localHash == baseline && originHash == baseline) return null;
    if (originHash == baseline) return SyncDirection.push;
    if (localHash == baseline) return SyncDirection.pull;
    // Both sides moved: refuse to guess.
    throw DriveConflictException(
      'mount "${record.id}" diverged: both local and remote changed — '
      'resolve with: omnyshell drive resolve ${record.id}',
    );
  }

  Future<SyncOutcome> _syncDirectory(
    MountRecord record,
    DriveRpcClient rpc,
    SyncDirection direction, {
    DriveProgress? onProgress,
  }) async {
    final sync = _directorySynchronizer(record, rpc);
    final mount = _mountInfo(record);
    final baseline = record.syncState.baselineRef;
    try {
      final plan = await sync.plan(
        mount: mount,
        baseline: baseline,
        direction: direction,
      );
      final result = await sync.apply(
        mount: mount,
        plan: plan,
        baseline: baseline,
        progress: onProgress == null ? null : ProgressReporter(onProgress),
      );
      final updated = record.copyWith(
        syncState: SyncState(
          baselineRef: result.newRef,
          currentRef: result.newRef,
          status: SyncStatus.clean,
          lastSyncedAt: DateTime.now(),
        ),
      );
      return SyncOutcome(
        record: updated,
        direction: direction,
        applied: result.appliedChanges,
      );
    } on ConflictDetectedException catch (e) {
      final updated = record.copyWith(
        syncState: record.syncState.copyWith(
          status: SyncStatus.conflicted,
          lastError: e.conflict.message,
        ),
      );
      store.mounts[record.id] = updated;
      await store.save();
      return SyncOutcome(record: updated, conflict: e.conflict);
    }
  }

  Future<SyncOutcome> _syncGit(
    MountRecord record,
    DriveRpcClient rpc,
    SyncDirection? direction, {
    DriveProgress? onProgress,
  }) async {
    final dir =
        direction ??
        (record.readWrite ? SyncDirection.push : SyncDirection.pull);
    // The node runs git atomically over a single RPC, so per-file events are
    // not available here; emit a coarse phase so a live bar still animates.
    _emit(
      onProgress,
      ProgressPhase.transferring,
      dir == SyncDirection.push ? 'pushing' : 'pulling',
    );
    final reply = await rpc.gitSync(
      url: record.gitUrl!,
      direction: dir.wireValue,
      baseline: record.syncState.baselineRef.value,
    );
    _emit(onProgress, ProgressPhase.done, 'synced');
    final conflict = reply['conflict'];
    if (conflict is Map) {
      final updated = record.copyWith(
        syncState: record.syncState.copyWith(
          status: SyncStatus.conflicted,
          lastError: conflict['message'] as String?,
        ),
      );
      return SyncOutcome(
        record: updated,
        conflict: Conflict(
          kind: ConflictKind.refMoved,
          driveId: DriveId(record.driveId),
          expectedRef: SyncRef.git(record.syncState.baselineRef.value),
          message: conflict['message'] as String? ?? 'git conflict',
        ),
      );
    }
    final head = reply['head'] as String;
    final updated = record.copyWith(
      syncState: SyncState(
        baselineRef: SyncRef.git(head),
        currentRef: SyncRef.git(head),
        status: SyncStatus.clean,
        lastSyncedAt: DateTime.now(),
      ),
    );
    return SyncOutcome(
      record: updated,
      direction: dir,
      applied: (reply['applied'] as num?)?.toInt() ?? 0,
      publishedBranch: reply['publishedBranch'] as String?,
    );
  }

  // --- Conflict resolution ---------------------------------------------------

  /// Resolves a conflict on [mountId]. [strategy] is `accept-local`,
  /// `accept-origin`, or `reclone`.
  Future<SyncOutcome> resolve(
    String mountId, {
    required String strategy,
    DriveProgress? onProgress,
  }) async {
    final record = require(mountId);
    final outcome = await _withSession(record, (rpc) async {
      if (record.isGit) {
        // Git: accepting the origin re-pulls; accepting local re-attempts push.
        final dir = strategy == 'accept-local'
            ? SyncDirection.push
            : SyncDirection.pull;
        return _syncGit(record, rpc, dir, onProgress: onProgress);
      }
      switch (strategy) {
        case 'accept-origin':
        case 'reclone':
          // Re-anchor on the origin and pull it down over the local copy.
          final originRef = (await ChannelContentSource(rpc).manifest()).hash();
          final reanchored = record.copyWith(
            syncState: record.syncState.copyWith(
              baselineRef: originRef,
              clearError: true,
              status: SyncStatus.clean,
            ),
          );
          return _syncDirectory(
            reanchored,
            rpc,
            SyncDirection.pull,
            onProgress: onProgress,
          );
        case 'accept-local':
        default:
          // Re-anchor on the current origin so the next push is not a conflict,
          // then overwrite the origin with the local copy.
          final originRef = (await ChannelContentSource(rpc).manifest()).hash();
          final reanchored = record.copyWith(
            syncState: record.syncState.copyWith(
              baselineRef: originRef,
              clearError: true,
              status: SyncStatus.clean,
            ),
          );
          return _syncDirectory(
            reanchored,
            rpc,
            SyncDirection.push,
            onProgress: onProgress,
          );
      }
    });
    store.mounts[mountId] = outcome.record;
    await store.save();
    return outcome;
  }

  // --- Watching --------------------------------------------------------------

  /// Watches [mountId] and auto-syncs on local changes and on an [interval]
  /// poll. Runs until [until] completes; when omitted it runs until the returned
  /// future is never completed (the caller cancels via process signal).
  /// Directory mounts also react to filesystem events.
  Future<void> watch(
    String mountId, {
    Duration interval = const Duration(seconds: 15),
    Duration debounce = const Duration(milliseconds: 500),
    void Function(String message)? log,
    DriveProgress? onProgress,
    Future<void>? until,
  }) async {
    final record = require(mountId);
    var running = false;
    Timer? debounceTimer;

    Future<void> trigger(String why) async {
      if (running) return;
      running = true;
      try {
        final o = await sync(mountId, onProgress: onProgress);
        if (o.isConflict) {
          log?.call('conflict ($why): ${o.conflict!.message}');
        } else if (o.direction != null) {
          log?.call(
            'synced ${o.direction!.wireValue} ($why): ${o.applied} change(s)',
          );
        }
      } on Object catch (e) {
        log?.call('sync failed ($why): $e');
      } finally {
        running = false;
      }
    }

    StreamSubscription<FileSystemEvent>? fsSub;
    if (!record.isGit && record.localPath != null) {
      fsSub = Directory(record.localPath!).watch(recursive: true).listen((_) {
        debounceTimer?.cancel();
        debounceTimer = Timer(debounce, () => trigger('fs'));
      });
    }
    final timer = Timer.periodic(interval, (_) => trigger('poll'));

    await trigger('initial');
    log?.call('watching ${record.id} (Ctrl-C to stop)');
    try {
      // Run until cancelled: either the caller-supplied [until] completes, or
      // (when none is given) the process is interrupted.
      await (until ?? Completer<void>().future);
    } finally {
      await fsSub?.cancel();
      timer.cancel();
      debounceTimer?.cancel();
    }
  }

  /// Re-establishes [mountId] after a node restart or fresh CLI run: git mounts
  /// re-clone (the node reuses an existing checkout), directory mounts re-anchor
  /// on the node and push the local copy back up.
  Future<MountRecord> remount(
    String mountId, {
    DriveProgress? onProgress,
  }) async {
    final record = require(mountId);
    final updated = await _withSession(record, (rpc) async {
      if (record.isGit) {
        _emit(
          onProgress,
          ProgressPhase.transferring,
          'cloning ${record.gitUrl}',
        );
        final head = await rpc.gitClone(
          record.gitUrl!,
          branch: record.gitBranch,
        );
        _emit(onProgress, ProgressPhase.done, 'cloned');
        return record.copyWith(
          syncState: SyncState(
            baselineRef: SyncRef.git(head),
            currentRef: SyncRef.git(head),
            status: SyncStatus.clean,
            lastSyncedAt: DateTime.now(),
          ),
        );
      }
      final originRef = (await ChannelContentSource(rpc).manifest()).hash();
      final reanchored = record.copyWith(
        syncState: record.syncState.copyWith(
          baselineRef: originRef,
          status: SyncStatus.clean,
          clearError: true,
        ),
      );
      return (await _syncDirectory(
        reanchored,
        rpc,
        SyncDirection.push,
        onProgress: onProgress,
      )).record;
    });
    store.mounts[mountId] = updated;
    await store.save();
    return updated;
  }

  // --- Unmounting ------------------------------------------------------------

  /// Unmounts [mountId]. With [syncFirst], runs a final sync; with
  /// [keepRemote] false, deletes the mount's files on the node (dir mounts only).
  Future<void> unmount(
    String mountId, {
    bool syncFirst = false,
    bool keepRemote = true,
  }) async {
    final record = require(mountId);
    if (syncFirst) {
      try {
        await sync(mountId);
      } on Object {
        // A failed final sync should not block teardown.
      }
    }
    if (!keepRemote && !record.isGit) {
      await _withSession(record, (rpc) async {
        final manifest = await ChannelContentSource(rpc).manifest();
        for (final path in manifest.sortedPaths) {
          await rpc.delete(path);
        }
        return record;
      });
    }
    store.mounts.remove(mountId);
    await store.save();
  }

  // --- Internals -------------------------------------------------------------

  static void _emit(DriveProgress? onProgress, ProgressPhase phase, String m) =>
      onProgress?.call(ProgressEvent(phase: phase, message: m));

  Future<RemoteSession> _open(MountRecord r) => client.openSession(
    nodeId: r.nodeId,
    mode: SessionMode.drive,
    command: r.remotePath,
    env: {
      DriveEnv.kind: r.kind,
      DriveEnv.readWrite: r.readWrite ? '1' : '0',
      if (!r.filter.isEmpty) DriveEnv.filter: jsonEncode(r.filter.toJson()),
    },
  );

  Future<T> _withSession<T>(
    MountRecord r,
    Future<T> Function(DriveRpcClient rpc) body,
  ) async {
    final session = await _open(r);
    final rpc = DriveRpcClient(session);
    try {
      return await body(rpc);
    } finally {
      await rpc.close();
    }
  }

  DirectorySynchronizer _directorySynchronizer(
    MountRecord record,
    DriveRpcClient rpc,
  ) {
    final drive = Drive(
      id: DriveId(record.driveId),
      name: record.name,
      provider: ProviderType.directory,
      originEndpoint: _endpointId(record.nodeId),
      originUri: OriginUri(record.remotePath),
      accessMode: record.accessMode,
      capabilities: DriveCapabilities.forProvider(
        ProviderType.directory,
        record.accessMode,
      ),
      filter: record.filter,
      createdAt: record.mountedAt,
    );
    return DirectorySynchronizer(
      drive: drive,
      resolveOrigin: ({required bool writable}) =>
          ChannelContentSource(rpc, isWritable: writable),
      resolveLocal: (path) => LocalContentSource(
        path,
        isWritable: true,
        filter: record.filter.isEmpty ? null : record.filter,
      ),
    );
  }

  MountInfo _mountInfo(MountRecord record) => MountInfo(
    id: MountId(record.id),
    driveId: DriveId(record.driveId),
    localPath: LocalPath(record.localPath!),
    accessMode: record.accessMode,
    mountType: MountType.mirror,
    mountedAt: record.mountedAt,
    syncState: record.syncState,
  );

  static final SyncRef _emptyDirRef = FileManifest.empty.hash();

  EndpointId _endpointId(String nodeId) {
    final raw = nodeId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-');
    final trimmed = raw.replaceAll(RegExp(r'^-+|-+$'), '');
    return EndpointId(trimmed.isEmpty ? 'node' : trimmed);
  }

  String _mountId(String nodeId, String name) {
    final base = '${_endpointId(nodeId).value}-${_slug(name)}';
    final suffix = DateTime.now().microsecondsSinceEpoch
        .toRadixString(16)
        .padLeft(4, '0');
    return '$base-${suffix.substring(suffix.length - 4)}';
  }

  static String _slug(String input) {
    final lower = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_.-]+'), '-');
    final trimmed = lower.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'drive' : trimmed;
  }

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? 'drive' : parts.last;
  }

  static String _gitName(String url) {
    var raw = url;
    if (raw.endsWith('/')) raw = raw.substring(0, raw.length - 1);
    if (raw.endsWith('.git')) raw = raw.substring(0, raw.length - 4);
    final seg = raw.split(RegExp(r'[\\/:]')).last;
    return seg.isEmpty ? 'repo' : seg;
  }
}

/// A general drive-management error surfaced to the CLI.
class DriveException implements Exception {
  /// The error message.
  final String message;

  /// Creates a drive exception.
  DriveException(this.message);

  @override
  String toString() => message;
}

/// Raised when an automatic sync cannot proceed because both sides changed.
class DriveConflictException extends DriveException {
  /// Creates a conflict exception.
  DriveConflictException(super.message);
}
