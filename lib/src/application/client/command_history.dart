/// Storage-agnostic command-history primitives, shared by every OmnyShell
/// client (the `dart:io` CLI and the browser web client alike).
///
/// This file is intentionally **pure Dart** — no `dart:io`, no I/O — so it
/// compiles to JavaScript. Persistence is left to the embedder: the CLI backs a
/// [CommandHistoryBuffer] with a `<home>/.omnyshell/history/<key>.history` file,
/// while the web client backs it with `localStorage`. Both reuse the same entry
/// rules ([CommandHistoryBuffer]) and the same Up/Down navigation
/// ([HistoryCursor]), so history behaves identically in either client.
library;

import 'dart:async';

/// A persistent command history a [LineEditor] can record into and navigate.
///
/// The storage-agnostic seam between the editor and a concrete history: the CLI
/// implements it with a file-backed `CommandHistory`, the web client with a
/// `localStorage`-backed one. [add] may be synchronous (web) or asynchronous
/// (file), so it returns `FutureOr<void>`.
abstract interface class CommandHistoryStore {
  /// Records [entry] (subject to the buffer's add rules) and persists it.
  FutureOr<void> add(String entry);

  /// A fresh Up/Down navigation cursor over the current entries.
  HistoryCursor cursor();
}

/// An ordered, bounded set of history entries with the shell's add rules.
///
/// Entries are newest-last and capped at [maxEntries] (oldest dropped first).
/// [add] skips blank lines and consecutive duplicates. The buffer holds no
/// persistence concern — embedders load entries into it and persist [entries]
/// after a mutation reports a change.
class CommandHistoryBuffer {
  final List<String> _entries;

  /// Upper bound on retained entries; oldest are dropped first.
  final int maxEntries;

  /// Creates a buffer seeded with [entries] (capped to [maxEntries]).
  CommandHistoryBuffer({List<String>? entries, this.maxEntries = 1000})
    : _entries = _capped(entries ?? const <String>[], maxEntries);

  /// The entries, oldest first. The returned list is an unmodifiable copy.
  List<String> get entries => List.unmodifiable(_entries);

  /// The number of entries currently held.
  int get length => _entries.length;

  /// Whether the buffer holds no entries.
  bool get isEmpty => _entries.isEmpty;

  /// Records [entry] unless it is blank or a consecutive duplicate of the most
  /// recent entry, capping to [maxEntries]. Returns whether the buffer changed,
  /// so callers can skip persisting on a no-op.
  bool add(String entry) {
    if (entry.trim().isEmpty) return false;
    if (_entries.isNotEmpty && _entries.last == entry) return false;
    _entries.add(entry);
    _cap();
    return true;
  }

  /// Replaces all entries with [entries] (used when loading from storage),
  /// capping to [maxEntries].
  void replaceAll(Iterable<String> entries) {
    _entries
      ..clear()
      ..addAll(entries);
    _cap();
  }

  /// Inserts [items] before the current entries (a migration splice), collapsing
  /// a duplicate that straddles the boundary (old tail == new head), then caps.
  /// A no-op when [items] is empty.
  void prepend(List<String> items) {
    if (items.isEmpty) return;
    _entries.insertAll(0, items);
    final boundary = items.length;
    if (boundary < _entries.length &&
        _entries[boundary - 1] == _entries[boundary]) {
      _entries.removeAt(boundary);
    }
    _cap();
  }

  void _cap() {
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  static List<String> _capped(Iterable<String> entries, int maxEntries) {
    final list = List<String>.of(entries);
    if (list.length > maxEntries) {
      return list.sublist(list.length - maxEntries);
    }
    return list;
  }

  /// Maps an arbitrary key (e.g. `<user>@<node>`) to a safe, stable identifier
  /// component — usable as a filename (CLI) or a storage-key suffix (web).
  static String sanitizeKey(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_.@-]'), '_');
    return safe.isEmpty ? '_' : safe;
  }
}

/// A reusable Up/Down navigation cursor over a [CommandHistoryBuffer].
///
/// Holds the browsing state the CLI's `LineEditor` and the web client's shell
/// host both need: the current index into the entries (`== length` while editing
/// a fresh line), the in-progress line stashed aside while browsing, and the
/// prefix that restricts which entries Up/Down visit.
///
/// The cursor never touches the caller's line buffer; [up]/[down] return the
/// text to display (or `null` to leave the current line unchanged), keeping it
/// agnostic to how the host stores and renders the line.
class HistoryCursor {
  final CommandHistoryBuffer _history;
  int _index;
  String _stash = '';
  String? _searchPrefix;

  /// Creates a cursor positioned past the newest entry (fresh-line state).
  HistoryCursor(this._history) : _index = _history.length;

  /// Moves to the previous (older) entry matching the active prefix, returning
  /// the line to show or `null` to leave the current line unchanged.
  ///
  /// On the first step from a fresh line it captures [line] (to restore on the
  /// way back down) and [prefix] (the text before the cursor — empty browses
  /// every entry); both are supplied by the caller so prefix computation can
  /// respect the host's own character model.
  String? up({required String line, required String prefix}) {
    final entries = _history.entries;
    if (_index == 0) return null;
    if (_index == entries.length) {
      _stash = line;
      _searchPrefix = prefix;
    }
    final active = _searchPrefix ?? '';
    for (var i = _index - 1; i >= 0; i--) {
      if (entries[i].startsWith(active)) {
        _index = i;
        return entries[i];
      }
    }
    // No earlier entry matches the prefix: keep the current line.
    return null;
  }

  /// Moves to the next (newer) matching entry, returning the line to show. Past
  /// the most recent match it restores the stashed in-progress line. Returns
  /// `null` when already on the fresh line.
  String? down() {
    final entries = _history.entries;
    if (_index >= entries.length) return null;
    final active = _searchPrefix ?? '';
    for (var i = _index + 1; i < entries.length; i++) {
      if (entries[i].startsWith(active)) {
        _index = i;
        return entries[i];
      }
    }
    _index = entries.length;
    return _stash;
  }

  /// Resets browsing so the next [up] recomputes the prefix from the current
  /// input. Call after any edit to the line and after recording a command.
  void reset() {
    _index = _history.length;
    _stash = '';
    _searchPrefix = null;
  }
}
