import 'dart:io';

import '../../shared/utils/omnyshell_home.dart';
import 'command_history.dart';

/// Persistent, per-key command history backed by a plain-text file.
///
/// Each key (typically `<user>@<node>`) maps to its own file under
/// `<home>/.omnyshell/history/<key>.history`, so connecting to different nodes
/// or as different principals never mixes histories. The home directory
/// resolves from `OMNYSHELL_HOME`, then `HOME`, then `USERPROFILE` — the same
/// convention used by the credential store.
///
/// The CLI's [CommandHistoryStore]; it reuses the shared [CommandHistoryBuffer]
/// (entry rules + cap + migration) and [HistoryCursor], adding only file
/// persistence. The browser client backs the same primitives with
/// `localStorage` instead.
class CommandHistory implements CommandHistoryStore {
  /// The shared, storage-agnostic entry buffer (add rules + cap + migration).
  final CommandHistoryBuffer _buffer;

  /// Backing file, or `null` for an in-memory-only history (e.g. in tests).
  final File? _file;

  CommandHistory._(this._buffer, this._file);

  /// Upper bound on retained entries; oldest are dropped first.
  int get maxEntries => _buffer.maxEntries;

  /// Loads the history for [key], returning an empty history when no file
  /// exists yet. Pass [home] to override the base directory (used by tests).
  static Future<CommandHistory> load({
    required String key,
    String? home,
    int maxEntries = 1000,
  }) async {
    final file = File(_path(key, home));
    final buffer = CommandHistoryBuffer(maxEntries: maxEntries);
    try {
      if (await file.exists()) {
        buffer.replaceAll(
          (await file.readAsLines()).where((l) => l.trim().isNotEmpty),
        );
      }
    } on Object {
      // A corrupt or unreadable history file must never break the shell.
    }
    return CommandHistory._(buffer, file);
  }

  /// An in-memory history with no backing file (used by tests).
  factory CommandHistory.inMemory({
    List<String>? entries,
    int maxEntries = 1000,
  }) => CommandHistory._(
    CommandHistoryBuffer(entries: entries, maxEntries: maxEntries),
    null,
  );

  /// The entries, oldest first. The returned list is a copy.
  List<String> get entries => _buffer.entries;

  /// Records [entry], skipping blank lines and consecutive duplicates, then
  /// persists the (trimmed-to-cap) history. IO failures are swallowed so the
  /// interactive session is never interrupted by a disk error.
  @override
  Future<void> add(String entry) async {
    if (_buffer.add(entry)) await _persist();
  }

  Future<void> _persist() async {
    final file = _file;
    if (file == null) return;
    try {
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        await _chmod(dir.path, '700');
      }
      await file.writeAsString('${_buffer.entries.join('\n')}\n');
      await _chmod(file.path, '600');
    } on Object {
      // Best-effort persistence only.
    }
  }

  /// Copies the history recorded under [fromKey] into [toKey], placing the
  /// migrated entries before any already present under [toKey] (consecutive
  /// duplicates are collapsed at the splice boundary). The [fromKey] file is
  /// left intact as a backup. A no-op when the source is missing or empty.
  ///
  /// Used when a node's UID changes: the caller migrates the prior UID's
  /// history into the new UID's history after the user opts in.
  static Future<void> migrate({
    required String fromKey,
    required String toKey,
    String? home,
    int maxEntries = 1000,
  }) async {
    final from = await load(key: fromKey, home: home, maxEntries: maxEntries);
    if (from.entries.isEmpty) return;
    final to = await load(key: toKey, home: home, maxEntries: maxEntries);
    to._buffer.prepend(from.entries.toList());
    await to._persist();
  }

  static String _path(String key, String? home) =>
      omnyshellPath(['history', '${sanitizeKey(key)}.history'], home: home);

  /// Maps an arbitrary key to a safe, stable filename component.
  static String sanitizeKey(String key) =>
      CommandHistoryBuffer.sanitizeKey(key);

  /// A fresh Up/Down navigation cursor over this history's entries.
  @override
  HistoryCursor cursor() => HistoryCursor(_buffer);

  static Future<void> _chmod(String path, String mode) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', [mode, path]);
    } on Object {
      // Permission hardening is best-effort.
    }
  }
}
