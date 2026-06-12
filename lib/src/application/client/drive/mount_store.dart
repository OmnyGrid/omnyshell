import 'dart:convert';
import 'dart:io';

import 'package:omnydrive/omnydrive.dart' hide Clock, SystemClock;

import '../../../shared/utils/omnyshell_home.dart';

/// A persisted record of one OmnyDrive mount the client manages.
///
/// A mount binds a local source (a directory, or a git URL) to a path on a
/// connected node. The synchronization anchor and last-known status live in
/// [syncState], reusing OmnyDrive's own types so the client and engine agree on
/// references.
class MountRecord {
  /// Stable mount id (e.g. `web-01-docs-3f2a`).
  final String id;

  /// The target node id.
  final String nodeId;

  /// Human-friendly mount name.
  final String name;

  /// `dir` or `git`.
  final String kind;

  /// The path the mount occupies on the node.
  final String remotePath;

  /// The local source directory (`dir` kind), if any.
  final String? localPath;

  /// The git repository URL (`git` kind), if any.
  final String? gitUrl;

  /// The git branch to track (`git` kind), if any.
  final String? gitBranch;

  /// Whether the node mirror is writable (changes can sync back).
  final bool readWrite;

  /// Whether the node path was auto-generated (an ephemeral `run`/`exec --mount`
  /// mount) rather than supplied via `--mount-path`. Lets `run` reuse a previous
  /// ephemeral mount for the same local dir without colliding with an explicit
  /// fixed-path mount.
  final bool ephemeral;

  /// The synthetic OmnyDrive drive id scoping this mount.
  final String driveId;

  /// When the mount was created.
  final DateTime mountedAt;

  /// The current synchronization state (baseline ref, status, last error).
  final SyncState syncState;

  /// Creates a mount record.
  MountRecord({
    required this.id,
    required this.nodeId,
    required this.name,
    required this.kind,
    required this.remotePath,
    required this.readWrite,
    required this.driveId,
    required this.mountedAt,
    required this.syncState,
    this.localPath,
    this.gitUrl,
    this.gitBranch,
    this.ephemeral = false,
  });

  /// Whether this is a git mount.
  bool get isGit => kind == 'git';

  /// The mount's access mode.
  AccessMode get accessMode =>
      readWrite ? AccessMode.readWrite : AccessMode.readOnly;

  /// Returns a copy with a new [syncState].
  MountRecord copyWith({SyncState? syncState}) => MountRecord(
    id: id,
    nodeId: nodeId,
    name: name,
    kind: kind,
    remotePath: remotePath,
    readWrite: readWrite,
    driveId: driveId,
    mountedAt: mountedAt,
    syncState: syncState ?? this.syncState,
    localPath: localPath,
    gitUrl: gitUrl,
    gitBranch: gitBranch,
    ephemeral: ephemeral,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nodeId': nodeId,
    'name': name,
    'kind': kind,
    'remotePath': remotePath,
    if (localPath != null) 'localPath': localPath,
    if (gitUrl != null) 'gitUrl': gitUrl,
    if (gitBranch != null) 'gitBranch': gitBranch,
    'readWrite': readWrite,
    if (ephemeral) 'ephemeral': true,
    'driveId': driveId,
    'mountedAt': mountedAt.toIso8601String(),
    'syncState': syncState.toJson(),
  };

  /// Decodes a record from JSON.
  factory MountRecord.fromJson(Map<String, dynamic> json) => MountRecord(
    id: json['id'] as String,
    nodeId: json['nodeId'] as String,
    name: json['name'] as String,
    kind: json['kind'] as String,
    remotePath: json['remotePath'] as String,
    localPath: json['localPath'] as String?,
    gitUrl: json['gitUrl'] as String?,
    gitBranch: json['gitBranch'] as String?,
    readWrite: json['readWrite'] as bool? ?? false,
    ephemeral: json['ephemeral'] as bool? ?? false,
    driveId: json['driveId'] as String,
    mountedAt: DateTime.parse(json['mountedAt'] as String),
    syncState: SyncState.fromJson(json['syncState'] as Map<String, dynamic>),
  );
}

/// On-disk registry of the client's OmnyDrive mounts.
///
/// Persisted to `<home>/.omnyshell/mounts.json` (file mode `600`), mirroring the
/// credential store. Keyed by mount id.
class MountStore {
  /// Mounts keyed by id.
  final Map<String, MountRecord> mounts;

  /// The home base this store reads/writes under (`null` uses the default
  /// `OMNYSHELL_HOME`/`HOME` resolution). Remembered so [save] targets the same
  /// location [load] used.
  final String? home;

  /// Creates a store over [mounts].
  MountStore({Map<String, MountRecord>? mounts, this.home})
    : mounts = mounts ?? <String, MountRecord>{};

  /// The mounts file path under [home].
  static String path({String? home}) =>
      omnyshellPath(['mounts.json'], home: home);

  /// Loads the store, returning an empty one when no file exists yet.
  static Future<MountStore> load({String? home}) async {
    final file = File(path(home: home));
    if (!await file.exists()) return MountStore(home: home);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final mounts = <String, MountRecord>{};
    final raw = json['mounts'];
    if (raw is Map) {
      raw.forEach((id, value) {
        mounts[id.toString()] = MountRecord.fromJson(
          (value as Map).cast<String, dynamic>(),
        );
      });
    }
    return MountStore(mounts: mounts, home: home);
  }

  /// Persists the store (dir mode `700`, file mode `600` on POSIX).
  Future<void> save() async {
    final file = File(path(home: home));
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _chmod(dir.path, '700');
    }
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'mounts': {for (final e in mounts.entries) e.key: e.value.toJson()},
      }),
    );
    await _chmod(file.path, '600');
  }

  static Future<void> _chmod(String path, String mode) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', [mode, path]);
  }
}
