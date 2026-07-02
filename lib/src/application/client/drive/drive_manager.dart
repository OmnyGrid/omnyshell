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

  /// Paths whose content was sent over the wire (directory mounts; empty for
  /// git, which syncs atomically on the node).
  final List<String> transferredPaths;

  /// Paths satisfied by a server-side copy of content already present (dedup).
  final List<String> copiedPaths;

  /// Paths deleted from the destination.
  final List<String> removedPaths;

  /// Uncompressed bytes of transferred content (excludes deduplicated copies).
  final int bytesTransferred;

  /// Bytes actually pushed over the wire, after any transport compression.
  final int bytesOnWire;

  /// True when this was a two-way auto-merge of non-overlapping changes (some
  /// paths pushed, others pulled) rather than a single-direction sync.
  final bool merged;

  /// For a [merged] sync, the paths reconciled toward the node (writes and
  /// deletes applied remotely).
  final List<String> pushedPaths;

  /// For a [merged] sync, the paths reconciled toward the local copy (writes
  /// and deletes applied locally).
  final List<String> pulledPaths;

  /// Creates a sync outcome.
  SyncOutcome({
    required this.record,
    this.direction,
    this.applied = 0,
    this.publishedBranch,
    this.conflict,
    this.transferredPaths = const [],
    this.copiedPaths = const [],
    this.removedPaths = const [],
    this.bytesTransferred = 0,
    this.bytesOnWire = 0,
    this.merged = false,
    this.pushedPaths = const [],
    this.pulledPaths = const [],
  });

  /// Whether the sync ended in a conflict.
  bool get isConflict => conflict != null;
}

/// Sink for live sync progress, fed omnydrive [ProgressEvent]s as each file is
/// uploaded/downloaded (directory mounts) or as a git push/clone advances.
typedef DriveProgress = void Function(ProgressEvent event);

/// Resolves the effective [PathFilter] for a directory mount, mirroring
/// `omnydrive publish`'s `.omnyignore` handling.
///
/// When [explicit] is non-null (the caller passed `--include`/`--exclude`, or a
/// derived whitelist) it wins unchanged — explicit filters override the ignore
/// file entirely. Otherwise the ignore file named [ignoreFileName] (default
/// [omnyIgnoreFileName]) is read from [localDir] and, if it yields any patterns,
/// returned as the drive's default `exclude` set. A missing/empty file yields
/// `null` (no filter), so the whole tree is published as before.
///
/// The resolved filter is computed once at the call site and passed to both the
/// mount-reuse lookup and [DriveManager.mountDirectory], so reuse matching and
/// the persisted record agree (see [DriveManager.findReusableDirMount]).
Future<PathFilter?> resolveDirMountFilter({
  required String localDir,
  PathFilter? explicit,
  String? ignoreFileName,
}) async {
  if (explicit != null) return explicit;
  final patterns = await loadOmnyIgnore(
    localDir,
    fileName: ignoreFileName ?? omnyIgnoreFileName,
  );
  if (patterns.isEmpty) return null;
  return PathFilter(exclude: patterns);
}

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
  /// *ephemeral* mount qualifies (its recorded path is reused). When [filter] is
  /// given (e.g. a `run --with` whitelist), the recorded filter must match too,
  /// so changing the co-mounted set creates a fresh mount instead of reusing one
  /// with a stale filter. The most recently mounted match wins.
  MountRecord? findReusableDirMount({
    required String nodeId,
    required String localDir,
    String? remotePath,
    PathFilter? filter,
  }) {
    final localAbs = p.normalize(Directory(localDir).absolute.path);
    final wantFilter = filter ?? PathFilter.empty;
    final matches = store.mounts.values.where((r) {
      if (r.isGit || r.kind != 'dir' || !r.readWrite) return false;
      if (r.nodeId != nodeId || r.localPath == null) return false;
      if (p.normalize(r.localPath!) != localAbs) return false;
      if (r.filter != wantFilter) return false;
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
      final originManifest = await ChannelContentSource(rpc).manifest();
      var r = record.copyWith(
        syncState: SyncState(
          baselineRef: originManifest.hash(),
          status: SyncStatus.clean,
        ),
        baselineManifest: originManifest,
      );
      if (initialSync) {
        r = (await _syncDirectory(
          r,
          rpc,
          SyncDirection.push,
          onProgress: onProgress,
        )).record;
        // After the push, local and node agree; snapshot the converged content.
        r = r.copyWith(baselineManifest: await _localSource(r).manifest());
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
      final clone = await rpc.gitClone(url, branch: branch, depth: depth);
      _emit(onProgress, ProgressPhase.done, 'cloned');
      return record.copyWith(
        currentBranch: clone.branch,
        syncState: SyncState(
          baselineRef: SyncRef.git(clone.head),
          currentRef: SyncRef.git(clone.head),
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
  /// on which side changed. When both sides changed, non-overlapping edits are
  /// auto-merged (local-only edits pushed, remote-only edits pulled) and only a
  /// path edited on both sides surfaces a conflict.
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
      if (direction != null) {
        return _syncDirectory(record, rpc, direction, onProgress: onProgress);
      }
      return _autoSync(record, rpc, onProgress: onProgress);
    });
    store.mounts[mountId] = outcome.record;
    await store.save();
    return outcome;
  }

  /// Picks a sync action automatically for a directory mount.
  ///
  /// Read-only mounts always push. For read-write mounts: when only one side
  /// moved off the baseline it is a plain push or pull; when both moved, a
  /// per-path 3-way merge against the persisted baseline manifest auto-applies
  /// non-overlapping changes (push local-only edits, pull remote-only edits)
  /// and only raises a conflict for paths edited on *both* sides. Without a
  /// trustworthy baseline manifest it falls back to flagging every content
  /// difference as a conflict.
  Future<SyncOutcome> _autoSync(
    MountRecord record,
    DriveRpcClient rpc, {
    DriveProgress? onProgress,
  }) async {
    if (!record.readWrite) {
      return _syncDirectory(
        record,
        rpc,
        SyncDirection.push,
        onProgress: onProgress,
      );
    }
    final baseline = record.syncState.baselineRef;
    final local = _localSource(record);
    final localManifest = await local.manifest();
    final originManifest = await ChannelContentSource(rpc).manifest();
    final localHash = localManifest.hash();
    final originHash = originManifest.hash();

    // Neither side moved: nothing to do. Opportunistically capture the baseline
    // manifest so a mount created before this snapshot existed gains one.
    if (localHash == baseline && originHash == baseline) {
      return SyncOutcome(
        record: _ensureBaselineManifest(record, localManifest),
      );
    }
    // Only one side moved off the baseline: a plain one-directional sync. Anchor
    // the new baseline manifest to the converged side so the next divergence can
    // be merged per-path.
    if (originHash == baseline) {
      return _attachBaseline(
        await _syncDirectory(
          record,
          rpc,
          SyncDirection.push,
          onProgress: onProgress,
        ),
        localManifest,
      );
    }
    if (localHash == baseline) {
      return _attachBaseline(
        await _syncDirectory(
          record,
          rpc,
          SyncDirection.pull,
          onProgress: onProgress,
        ),
        originManifest,
      );
    }
    // Both sides moved to the *same* content (the tree hash excludes mtime and
    // the exec bit): no real conflict, just re-anchor without transferring.
    if (localHash == originHash) {
      return SyncOutcome(record: _reanchor(record, localManifest));
    }

    // Both sides moved differently. Classify per path against the baseline.
    final base = record.baselineManifest;
    if (base == null || base.hash() != baseline) {
      // No trustworthy baseline snapshot (legacy mount, or a baseline advanced
      // by an explicit push/pull): cannot tell one-sided edits from conflicts,
      // so fall back to flagging every content difference.
      throw DriveConflictException(
        _divergedMessage(
          record,
          _contentDivergedPaths(localManifest, originManifest),
        ),
      );
    }
    final plan = _mergePlan(base, localManifest, originManifest);
    if (plan.conflicts.isNotEmpty) {
      throw DriveConflictException(_divergedMessage(record, plan.conflicts));
    }
    return _applyMerge(
      record,
      rpc,
      local,
      plan,
      localManifest,
      originManifest,
      onProgress: onProgress,
    );
  }

  /// Returns [record] with [manifest] recorded as the baseline manifest when the
  /// mount currently lacks an up-to-date one (its hash must match the baseline).
  MountRecord _ensureBaselineManifest(
    MountRecord record,
    FileManifest manifest,
  ) {
    final current = record.baselineManifest;
    if (current != null && current.hash() == record.syncState.baselineRef) {
      return record;
    }
    return record.copyWith(baselineManifest: manifest);
  }

  /// Records [manifest] (the now-converged content) as the baseline manifest of
  /// a successful one-directional sync [outcome].
  SyncOutcome _attachBaseline(SyncOutcome outcome, FileManifest manifest) {
    if (outcome.isConflict) return outcome;
    return SyncOutcome(
      record: outcome.record.copyWith(baselineManifest: manifest),
      direction: outcome.direction,
      applied: outcome.applied,
      publishedBranch: outcome.publishedBranch,
      transferredPaths: outcome.transferredPaths,
      copiedPaths: outcome.copiedPaths,
      removedPaths: outcome.removedPaths,
      bytesTransferred: outcome.bytesTransferred,
      bytesOnWire: outcome.bytesOnWire,
    );
  }

  /// Re-anchors [record] clean on [manifest]'s content (both sides already
  /// agree), advancing both the baseline ref and the baseline manifest.
  MountRecord _reanchor(MountRecord record, FileManifest manifest) {
    final ref = manifest.hash();
    return record.copyWith(
      syncState: SyncState(
        baselineRef: ref,
        currentRef: ref,
        status: SyncStatus.clean,
        lastSyncedAt: DateTime.now(),
      ),
      baselineManifest: manifest,
    );
  }

  /// Applies a non-overlapping [plan]: pushes local-only changes to the node and
  /// pulls remote-only changes to the local copy, then re-anchors the mount on
  /// the merged result.
  Future<SyncOutcome> _applyMerge(
    MountRecord record,
    DriveRpcClient rpc,
    LocalContentSource local,
    _MergePlan plan,
    FileManifest localManifest,
    FileManifest originManifest, {
    DriveProgress? onProgress,
  }) async {
    for (final path in plan.toRemote) {
      _emit(onProgress, ProgressPhase.transferring, 'pushing $path');
      await rpc.write(
        path,
        await local.readBytes(path),
        executable: localManifest.entries[path]!.executable,
      );
    }
    for (final path in plan.removeRemote) {
      _emit(onProgress, ProgressPhase.transferring, 'removing $path on node');
      await rpc.delete(path);
    }
    for (final path in plan.toLocal) {
      _emit(onProgress, ProgressPhase.transferring, 'pulling $path');
      await local.writeBytes(
        path,
        await rpc.read(path),
        executable: originManifest.entries[path]!.executable,
      );
    }
    for (final path in plan.removeLocal) {
      _emit(onProgress, ProgressPhase.transferring, 'removing $path locally');
      await local.delete(path);
    }
    _emit(onProgress, ProgressPhase.done, 'merged');
    // Local and node now agree; re-anchor on the merged content.
    final merged = await local.manifest();
    final pushed = [...plan.toRemote, ...plan.removeRemote]..sort();
    final pulled = [...plan.toLocal, ...plan.removeLocal]..sort();
    return SyncOutcome(
      record: _reanchor(record, merged),
      merged: true,
      applied: pushed.length + pulled.length,
      pushedPaths: pushed,
      pulledPaths: pulled,
    );
  }

  /// Classifies every path against the [base] baseline into one-sided changes
  /// (auto-mergeable) and true two-sided [conflicts]. Comparison is by content
  /// hash only, so executable-bit-only differences are not treated as changes.
  static _MergePlan _mergePlan(
    FileManifest base,
    FileManifest local,
    FileManifest origin,
  ) {
    final toRemote = <String>[];
    final removeRemote = <String>[];
    final toLocal = <String>[];
    final removeLocal = <String>[];
    final conflicts = <String>[];
    final all = <String>{
      ...base.entries.keys,
      ...local.entries.keys,
      ...origin.entries.keys,
    };
    for (final path in all) {
      final b = base.entries[path]?.hash;
      final l = local.entries[path]?.hash;
      final o = origin.entries[path]?.hash;
      final localChanged = l != b;
      final remoteChanged = o != b;
      if (!localChanged && !remoteChanged) continue;
      if (localChanged && !remoteChanged) {
        (l == null ? removeRemote : toRemote).add(path);
      } else if (remoteChanged && !localChanged) {
        (o == null ? removeLocal : toLocal).add(path);
      } else if (l != o) {
        // Both sides changed the same path to different content.
        conflicts.add(path);
      }
      // Both changed to the same content: nothing to do.
    }
    return _MergePlan(
      toRemote: toRemote..sort(),
      removeRemote: removeRemote..sort(),
      toLocal: toLocal..sort(),
      removeLocal: removeLocal..sort(),
      conflicts: conflicts..sort(),
    );
  }

  /// Paths whose *content* differs between [local] and [origin] — present on one
  /// side only, or present on both with a different content hash. Excludes
  /// executable-bit-only differences (which the tree hash and `drive diff` also
  /// ignore) so the conflict list matches what `drive diff` reports; on a
  /// Windows node, where the exec bit is always false, those would otherwise be
  /// reported as phantom divergences.
  static List<String> _contentDivergedPaths(
    FileManifest local,
    FileManifest origin,
  ) {
    final paths = <String>{};
    for (final path in local.sortedPaths) {
      final o = origin.entries[path];
      if (o == null || o.hash != local.entries[path]!.hash) paths.add(path);
    }
    for (final path in origin.sortedPaths) {
      if (!local.entries.containsKey(path)) paths.add(path);
    }
    return paths.toList()..sort();
  }

  /// Builds the conflict message for a two-sided divergence, listing the
  /// content-diverged [paths] (capped to keep the output readable).
  static String _divergedMessage(MountRecord record, List<String> paths) {
    final buffer = StringBuffer()
      ..write('mount "${record.id}" diverged: both local and remote changed — ')
      ..write('resolve with: omnyshell drive resolve ${record.id}');
    if (paths.isNotEmpty) {
      const limit = 20;
      buffer.write(
        '\n${paths.length} diverged path${paths.length == 1 ? '' : 's'}:',
      );
      for (final path in paths.take(limit)) {
        buffer.write('\n  $path');
      }
      if (paths.length > limit) {
        buffer.write('\n  … and ${paths.length - limit} more');
      }
    }
    return buffer.toString();
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
      final m = result.metrics;
      return SyncOutcome(
        record: updated,
        direction: direction,
        applied: result.appliedChanges,
        transferredPaths: m.transferredPaths,
        copiedPaths: m.copiedPaths,
        removedPaths: m.removedPaths,
        bytesTransferred: m.bytesTransferred,
        bytesOnWire: m.bytesOnWire,
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
    // Auto (no explicit direction) on a read-write mount pushes the node's
    // unpushed commits first, then pulls to reconcile. An explicit direction —
    // or a read-only mount — runs a single pass.
    if (direction == null && record.readWrite) {
      final pushed = await _gitSyncOnce(
        record,
        rpc,
        SyncDirection.push,
        onProgress: onProgress,
      );
      if (pushed.conflict != null) return pushed;
      return _gitSyncOnce(
        pushed.record,
        rpc,
        SyncDirection.pull,
        onProgress: onProgress,
      );
    }
    return _gitSyncOnce(
      record,
      rpc,
      direction ?? SyncDirection.pull,
      onProgress: onProgress,
    );
  }

  Future<SyncOutcome> _gitSyncOnce(
    MountRecord record,
    DriveRpcClient rpc,
    SyncDirection dir, {
    DriveProgress? onProgress,
  }) async {
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
      mountBranch: record.gitBranch,
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
      currentBranch: reply['branch'] as String?,
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
          final originManifest = await ChannelContentSource(rpc).manifest();
          final reanchored = record.copyWith(
            syncState: record.syncState.copyWith(
              baselineRef: originManifest.hash(),
              clearError: true,
              status: SyncStatus.clean,
            ),
          );
          // After the pull local matches the origin: snapshot it as the baseline.
          return _attachBaseline(
            await _syncDirectory(
              reanchored,
              rpc,
              SyncDirection.pull,
              onProgress: onProgress,
            ),
            originManifest,
          );
        case 'accept-local':
        default:
          return _pushLocalAuthoritative(record, rpc, onProgress: onProgress);
      }
    });
    store.mounts[mountId] = outcome.record;
    await store.save();
    return outcome;
  }

  /// Makes the node mirror the local copy regardless of any remote divergence:
  /// re-anchors the baseline on the current origin so the push is never flagged
  /// as a conflict, overwrites the origin with the local copy (writing local
  /// files and deleting remote-only ones), then snapshots the pushed-up local
  /// content as the new baseline. Never reads, modifies, or deletes anything in
  /// the local directory.
  ///
  /// Shared by `resolve --accept-local` and [pushLocalMirror].
  Future<SyncOutcome> _pushLocalAuthoritative(
    MountRecord record,
    DriveRpcClient rpc, {
    DriveProgress? onProgress,
  }) async {
    final originRef = (await ChannelContentSource(rpc).manifest()).hash();
    final reanchored = record.copyWith(
      syncState: record.syncState.copyWith(
        baselineRef: originRef,
        clearError: true,
        status: SyncStatus.clean,
      ),
    );
    // After the push the node matches local: snapshot it as the baseline.
    return _attachBaseline(
      await _syncDirectory(
        reanchored,
        rpc,
        SyncDirection.push,
        onProgress: onProgress,
      ),
      await _localSource(record).manifest(),
    );
  }

  /// First sync of a *reused* directory mount: pushes the local copy up so the
  /// node mirrors it exactly, reusing files already present on the node. Unlike
  /// the two-way [sync], this is authoritative local→remote — it never pulls,
  /// modifies, or deletes anything in the local directory, and never raises a
  /// conflict (see [_pushLocalAuthoritative]).
  Future<SyncOutcome> pushLocalMirror(
    String mountId, {
    DriveProgress? onProgress,
  }) async {
    final record = require(mountId);
    final outcome = await _withSession(record, (rpc) async {
      if (record.isGit) {
        return _syncGit(
          record,
          rpc,
          SyncDirection.push,
          onProgress: onProgress,
        );
      }
      return _pushLocalAuthoritative(record, rpc, onProgress: onProgress);
    });
    store.mounts[mountId] = outcome.record;
    await store.save();
    return outcome;
  }

  /// Compares one [path] on a directory mount's local copy against the node.
  ///
  /// The bytes of both sides are only transferred for a small, textual file
  /// (see [_maxInlineDiffBytes]); for big or binary files the result carries
  /// just the size/hash of each side so the caller can report the difference
  /// without moving the content.
  Future<FileDiff> diffFile(String mountId, String path) async {
    final record = require(mountId);
    if (record.isGit) {
      throw DriveException('drive diff is only supported for directory mounts');
    }
    return _withSession(record, (rpc) async {
      final local = _localSource(record);
      final localManifest = await local.manifest();
      final originManifest = await ChannelContentSource(rpc).manifest();
      return _buildFileDiff(
        record,
        rpc,
        local,
        localManifest,
        originManifest,
        path,
      );
    });
  }

  /// Builds the [FileDiff] for [path] from already-fetched manifests, reading
  /// bytes only for a small, textual file (binary/oversized files carry just the
  /// size/hash summary). Shared by [diffFile] and [conflicts].
  Future<FileDiff> _buildFileDiff(
    MountRecord record,
    DriveRpcClient rpc,
    LocalContentSource local,
    FileManifest localManifest,
    FileManifest originManifest,
    String path,
  ) async {
    final localEntry = localManifest.entries[path];
    final originEntry = originManifest.entries[path];
    if (localEntry == null && originEntry == null) {
      throw DriveException('path not found on either side: $path');
    }
    // Classify which side moved relative to the baseline so the diff can say
    // whether this is a one-sided change (push/pull) or a real conflict.
    final side = _classifyDivergence(record, path, localEntry, originEntry);
    if (localEntry != null &&
        originEntry != null &&
        localEntry.hash == originEntry.hash) {
      return FileDiff(
        path: path,
        local: localEntry,
        origin: originEntry,
        side: side,
      );
    }
    // Skip the byte transfer entirely when either side is too large to diff
    // inline — the size/hash summary is enough to see that they diverge.
    final localSize = localEntry?.size ?? 0;
    final originSize = originEntry?.size ?? 0;
    if (localSize > _maxInlineDiffBytes || originSize > _maxInlineDiffBytes) {
      return FileDiff(
        path: path,
        local: localEntry,
        origin: originEntry,
        side: side,
        tooLarge: true,
      );
    }
    final localBytes = localEntry == null ? null : await local.readBytes(path);
    final originBytes = originEntry == null ? null : await rpc.read(path);
    if (_looksBinary(localBytes) || _looksBinary(originBytes)) {
      return FileDiff(
        path: path,
        local: localEntry,
        origin: originEntry,
        side: side,
        binary: true,
      );
    }
    return FileDiff(
      path: path,
      local: localEntry,
      origin: originEntry,
      side: side,
      localBytes: localBytes,
      originBytes: originBytes,
    );
  }

  /// Determines, for [path], whether the local copy, the node, or both moved off
  /// the baseline — using the persisted baseline manifest. Returns
  /// [FileDivergence.unknown] when no trustworthy baseline snapshot is available
  /// (a legacy mount, or one whose baseline advanced via an explicit push/pull).
  static FileDivergence _classifyDivergence(
    MountRecord record,
    String path,
    FileManifestEntry? localEntry,
    FileManifestEntry? originEntry,
  ) {
    if (localEntry?.hash == originEntry?.hash) return FileDivergence.none;
    final base = record.baselineManifest;
    if (base == null || base.hash() != record.syncState.baselineRef) {
      return FileDivergence.unknown;
    }
    final baseHash = base.entries[path]?.hash;
    final localChanged = localEntry?.hash != baseHash;
    final remoteChanged = originEntry?.hash != baseHash;
    if (localChanged && remoteChanged) return FileDivergence.bothSides;
    if (localChanged) return FileDivergence.localOnly;
    if (remoteChanged) return FileDivergence.remoteOnly;
    return FileDivergence.none;
  }

  /// Lists every path that differs between the local copy and the node for a
  /// directory mount, grouped by which side changed — true conflicts (both
  /// sides), local-only changes (a sync would push), and remote-only changes (a
  /// sync would pull). Read-only: it performs no sync, resolve, or state change.
  ///
  /// Without a trustworthy baseline snapshot the side cannot be determined, so
  /// the differing paths are returned in [DriveChanges.unknown].
  /// With [includeDiffs], the [FileDiff] of each diffable path is also computed
  /// within the same session and returned in [DriveChanges.diffs] — the
  /// conflicting paths when a baseline is known, or every differing path when it
  /// is not (so `--diff` is useful even for an unclassified, legacy mount).
  Future<DriveChanges> conflicts(
    String mountId, {
    bool includeDiffs = false,
  }) async {
    final record = require(mountId);
    if (record.isGit) {
      throw DriveException(
        'drive conflicts is only supported for directory mounts',
      );
    }
    return _withSession(record, (rpc) async {
      final local = _localSource(record);
      final localManifest = await local.manifest();
      final originManifest = await ChannelContentSource(rpc).manifest();
      // Builds the per-path diffs for [paths] within this session, when asked.
      Future<Map<String, FileDiff>> diffsFor(List<String> paths) async {
        if (!includeDiffs || paths.isEmpty) return const {};
        final map = <String, FileDiff>{};
        for (final path in paths) {
          map[path] = await _buildFileDiff(
            record,
            rpc,
            local,
            localManifest,
            originManifest,
            path,
          );
        }
        return map;
      }

      final base = record.baselineManifest;
      if (base == null || base.hash() != record.syncState.baselineRef) {
        // No baseline snapshot: we can list differing paths but not classify
        // them. With --diff, still show each one's diff.
        final unknown = _contentDivergedPaths(localManifest, originManifest);
        return DriveChanges(unknown: unknown, diffs: await diffsFor(unknown));
      }
      final plan = _mergePlan(base, localManifest, originManifest);
      return DriveChanges(
        localOnly: [...plan.toRemote, ...plan.removeRemote]..sort(),
        remoteOnly: [...plan.toLocal, ...plan.removeLocal]..sort(),
        conflicts: plan.conflicts,
        diffs: await diffsFor(plan.conflicts),
      );
    });
  }

  /// Resolves a single [path] on a directory mount by copying its bytes one
  /// way: `accept-local` overwrites the node, `accept-origin` overwrites the
  /// local copy. When the path is absent on the accepted side the other side
  /// is removed. If the file was the mount's last divergence the mount is
  /// re-anchored clean; otherwise its conflicted state is left untouched.
  Future<FileResolveOutcome> resolveFile(
    String mountId,
    String path, {
    required String strategy,
    DriveProgress? onProgress,
  }) async {
    final record = require(mountId);
    if (record.isGit) {
      throw DriveException(
        'per-file resolve is only supported for directory mounts',
      );
    }
    if (strategy != 'accept-local' && strategy != 'accept-origin') {
      throw DriveException(
        'per-file resolve needs --accept-local or --accept-origin',
      );
    }
    final outcome = await _withSession(record, (rpc) async {
      final local = _localSource(record);
      final localEntry = (await local.manifest()).entries[path];
      final originEntry = (await ChannelContentSource(
        rpc,
      ).manifest()).entries[path];
      if (localEntry == null && originEntry == null) {
        throw DriveException('path not found on either side: $path');
      }
      if (strategy == 'accept-origin') {
        if (originEntry == null) {
          await local.delete(path);
        } else {
          _emit(onProgress, ProgressPhase.transferring, 'pulling $path');
          final bytes = await rpc.read(path);
          await local.writeBytes(
            path,
            bytes,
            executable: originEntry.executable,
          );
        }
      } else {
        if (localEntry == null) {
          await rpc.delete(path);
        } else {
          _emit(onProgress, ProgressPhase.transferring, 'pushing $path');
          final bytes = await local.readBytes(path);
          await rpc.write(path, bytes, executable: localEntry.executable);
        }
      }
      _emit(onProgress, ProgressPhase.done, 'resolved $path');
      // Re-read both sides: if the whole tree now matches, the divergence is
      // gone and we can re-anchor the mount clean. Otherwise leave it alone —
      // other paths still conflict.
      final newLocal = await local.manifest();
      final newOriginHash = (await ChannelContentSource(rpc).manifest()).hash();
      final converged = newLocal.hash() == newOriginHash;
      final updated = converged ? _reanchor(record, newLocal) : record;
      return FileResolveOutcome(
        record: updated,
        path: path,
        strategy: strategy,
        converged: converged,
      );
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
        } else if (o.merged) {
          log?.call(
            'merged ($why): pushed ${o.pushedPaths.length}, '
            'pulled ${o.pulledPaths.length}',
          );
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
        final clone = await rpc.gitClone(
          record.gitUrl!,
          branch: record.gitBranch,
        );
        _emit(onProgress, ProgressPhase.done, 'cloned');
        return record.copyWith(
          currentBranch: clone.branch,
          syncState: SyncState(
            baselineRef: SyncRef.git(clone.head),
            currentRef: SyncRef.git(clone.head),
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
      final pushed = (await _syncDirectory(
        reanchored,
        rpc,
        SyncDirection.push,
        onProgress: onProgress,
      )).record;
      // After the push the node mirrors local: snapshot it as the baseline.
      return pushed.copyWith(
        baselineManifest: await _localSource(record).manifest(),
      );
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

  /// The most bytes a single side may have before `drive diff` falls back to a
  /// size/hash summary instead of transferring and rendering the content.
  static const _maxInlineDiffBytes = 256 * 1024;

  LocalContentSource _localSource(MountRecord record) => LocalContentSource(
    record.localPath!,
    filter: record.filter.isEmpty ? null : record.filter,
  );

  /// Heuristic binary check: a NUL byte in the leading window means the content
  /// is not text (the same signal git uses).
  static bool _looksBinary(List<int>? bytes) {
    if (bytes == null) return false;
    final limit = bytes.length < 8000 ? bytes.length : 8000;
    for (var i = 0; i < limit; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

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

/// The per-path plan for a two-way auto-merge: which paths to reconcile toward
/// the node, which toward the local copy, and which conflict on both sides.
class _MergePlan {
  /// Local-only edits to write to the node.
  final List<String> toRemote;

  /// Local-only deletions to apply on the node.
  final List<String> removeRemote;

  /// Remote-only edits to write to the local copy.
  final List<String> toLocal;

  /// Remote-only deletions to apply locally.
  final List<String> removeLocal;

  /// Paths edited on both sides to different content — unmergeable.
  final List<String> conflicts;

  const _MergePlan({
    required this.toRemote,
    required this.removeRemote,
    required this.toLocal,
    required this.removeLocal,
    required this.conflicts,
  });
}

/// Which side of a mount moved off the baseline for a given path. Drives how a
/// difference is described and how `drive sync` would reconcile it.
enum FileDivergence {
  /// No content difference between local and node.
  none,

  /// Changed only in the local copy — `drive sync` will push it.
  localOnly,

  /// Changed only on the node — `drive sync` will pull it.
  remoteOnly,

  /// Changed on both sides to different content — a real conflict.
  bothSides,

  /// No trustworthy baseline snapshot, so the side that changed is unknown.
  unknown,
}

/// The set of paths that differ between a directory mount's local copy and the
/// node, grouped by which side changed. Produced read-only by
/// [DriveManager.conflicts] — no sync or resolve is performed.
class DriveChanges {
  /// Paths edited on both sides to different content — true conflicts.
  final List<String> conflicts;

  /// Paths changed only locally — a sync would push them.
  final List<String> localOnly;

  /// Paths changed only on the node — a sync would pull them.
  final List<String> remoteOnly;

  /// Paths that differ but whose changed side is unknown (no baseline snapshot).
  final List<String> unknown;

  /// Per-conflict diffs, keyed by path — populated only when the caller asked
  /// for them (see [DriveManager.conflicts]); empty otherwise.
  final Map<String, FileDiff> diffs;

  /// Creates a changes summary.
  DriveChanges({
    this.conflicts = const [],
    this.localOnly = const [],
    this.remoteOnly = const [],
    this.unknown = const [],
    this.diffs = const {},
  });

  /// True when local and node fully agree.
  bool get isEmpty =>
      conflicts.isEmpty &&
      localOnly.isEmpty &&
      remoteOnly.isEmpty &&
      unknown.isEmpty;

  /// True when at least one path was edited on both sides.
  bool get hasConflicts => conflicts.isNotEmpty;

  /// Total number of differing paths.
  int get total =>
      conflicts.length + localOnly.length + remoteOnly.length + unknown.length;
}

/// The comparison of one path between a directory mount's local copy and the
/// node. At most one of [local]/[origin] is null (an absent side).
class FileDiff {
  /// Forward-slash relative path that was compared.
  final String path;

  /// The local entry, or null when the file is absent locally.
  final FileManifestEntry? local;

  /// The origin entry, or null when the file is absent on the node.
  final FileManifestEntry? origin;

  /// Which side moved off the baseline (and thus how a sync would reconcile it).
  final FileDivergence side;

  /// Local bytes — populated only for a small, textual file; null otherwise.
  final List<int>? localBytes;

  /// Origin bytes — populated only for a small, textual file; null otherwise.
  final List<int>? originBytes;

  /// True when at least one present side holds binary content.
  final bool binary;

  /// True when at least one side exceeds the inline-diff size limit.
  final bool tooLarge;

  /// Creates a file diff result.
  FileDiff({
    required this.path,
    this.local,
    this.origin,
    this.side = FileDivergence.unknown,
    this.localBytes,
    this.originBytes,
    this.binary = false,
    this.tooLarge = false,
  });

  /// True when both sides exist and hash identically.
  bool get identical =>
      local != null && origin != null && local!.hash == origin!.hash;

  /// True when content bytes are available for a line-level diff.
  bool get hasContent => localBytes != null || originBytes != null;
}

/// The outcome of resolving a single path on a directory mount.
class FileResolveOutcome {
  /// The (possibly re-anchored) mount record after resolution.
  final MountRecord record;

  /// The path that was resolved.
  final String path;

  /// The strategy applied: `accept-local` or `accept-origin`.
  final String strategy;

  /// True when this was the mount's last divergence, so it is now clean.
  final bool converged;

  /// Creates a per-file resolve outcome.
  FileResolveOutcome({
    required this.record,
    required this.path,
    required this.strategy,
    required this.converged,
  });
}
