import 'dart:convert';
import 'dart:io';

import '../../domain/value_objects/omny_uid.dart';
import '../../shared/json/json_codec_helpers.dart';
import '../../shared/utils/omnyshell_home.dart';

/// The outcome of resolving an entity's UID against its persisted value.
class UidResolution {
  /// The current (authoritative) UID.
  final OmnyUid uid;

  /// Whether this is the first time a UID was recorded for this entity.
  final bool firstRun;

  /// Whether the recomputed UID differs from the previously stored one.
  final bool changed;

  /// The prior UID, when [changed] is true.
  final OmnyUid? previous;

  const UidResolution({
    required this.uid,
    required this.firstRun,
    required this.changed,
    this.previous,
  });
}

/// Persists an entity's UID under `~/.omnyshell/<fileName>` and detects changes.
///
/// On every start the caller recomputes the UID from live material and passes it
/// to [resolve]; the store compares it against the persisted value, records the
/// new value (retiring the old one into a history list) and reports whether it
/// changed so the caller can warn loudly — a UID change is significant because it
/// means the entity's identity material moved.
class UidStore {
  /// The file name under `~/.omnyshell/`, e.g. `node.uid` or `hub.uid`.
  final String fileName;

  /// Overrides the home directory (primarily for tests).
  final String? home;

  const UidStore({required this.fileName, this.home});

  /// The absolute path of the backing file.
  String get path => omnyshellPath([fileName], home: home);

  /// Resolves [current] against the persisted UID, persisting the new value and
  /// returning whether it changed. Emits an info/warning line via [logger].
  Future<UidResolution> resolve(
    OmnyUid current, {
    void Function(String message)? logger,
  }) async {
    final file = File(path);
    final now = DateTime.now().toUtc();

    if (!await file.exists()) {
      await _write(file, uid: current, computedAt: now, previous: const []);
      logger?.call('identity established: ${current.value}');
      return UidResolution(uid: current, firstRun: true, changed: false);
    }

    String? storedValue;
    List<Map<String, dynamic>> previous = const [];
    try {
      final json = Json.asObject(
        jsonDecode(await file.readAsString()),
        'uid file',
      );
      storedValue = Json.optString(json, 'uid');
      final rawPrev = json['previous'];
      if (rawPrev is List) {
        previous = rawPrev
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      }
    } on Object {
      storedValue = null; // Corrupt file — treat as a re-establishment.
    }

    if (storedValue == current.value) {
      return UidResolution(uid: current, firstRun: false, changed: false);
    }

    final retired = [
      ...previous,
      if (storedValue != null)
        {'uid': storedValue, 'retiredAt': now.toIso8601String()},
    ];
    await _write(file, uid: current, computedAt: now, previous: retired);

    final old = storedValue == null ? null : OmnyUid(storedValue);
    logger?.call(
      old == null
          ? 'identity re-established: ${current.value}'
          : '⚠ UID changed: ${old.value} -> ${current.value} '
                '(identity material changed; this is significant)',
    );
    return UidResolution(
      uid: current,
      firstRun: false,
      changed: true,
      previous: old,
    );
  }

  Future<void> _write(
    File file, {
    required OmnyUid uid,
    required DateTime computedAt,
    required List<Map<String, dynamic>> previous,
  }) async {
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _chmod(dir.path, '700');
    }
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'uid': uid.value,
        'computedAt': computedAt.toIso8601String(),
        'previous': previous,
      }),
    );
    await _chmod(file.path, '600');
  }

  static Future<void> _chmod(String path, String mode) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', [mode, path]);
    } on Object {
      // Best-effort only.
    }
  }
}
