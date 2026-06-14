import 'dart:convert';
import 'dart:io';

import 'package:omnydrive/omnydrive.dart'
    show
        FileManifestEntry,
        ProgressEvent,
        ProgressPhase,
        ProgressItemKind,
        ProgressItemState;

import '../../application/client/drive/drive_manager.dart'
    show DriveChanges, FileDiff, FileDivergence, SyncOutcome;
import '../../application/transfer/transfer_engine.dart';

/// A single-line, carriage-return progress bar for file transfers.
///
/// Renders `[######----] 62%  4.1/6.6 MB  1.2 MB/s name` in place, throttled to
/// a few updates a second. A no-op when stdout is not a terminal (or `NO_COLOR`
/// is set), so piped/redirected output stays clean.
class ProgressBar {
  final IOSink _out;
  final bool _enabled;
  final int _width;
  final Stopwatch _sw = Stopwatch()..start();
  int _lastLen = 0;
  int _lastRenderMs = -1000;

  /// Creates a progress bar writing to [out] (defaults to stdout).
  ProgressBar({IOSink? out, bool? enabled, int width = 24})
    : _out = out ?? stdout,
      _width = width,
      _enabled =
          enabled ??
          (stdout.hasTerminal && !Platform.environment.containsKey('NO_COLOR'));

  /// Renders [p], throttled; safe to call on every chunk.
  void update(TransferProgress p) {
    if (!_enabled) return;
    final ms = _sw.elapsedMilliseconds;
    final complete = p.bytesDone >= p.bytesTotal;
    if (!complete && ms - _lastRenderMs < 100) return;
    _lastRenderMs = ms;

    final frac = p.bytesTotal == 0 ? 1.0 : p.bytesDone / p.bytesTotal;
    final pct = (frac * 100).clamp(0, 100).toStringAsFixed(0).padLeft(3);
    final filled = (frac * _width).round().clamp(0, _width);
    final bar = '#' * filled + '-' * (_width - filled);
    final secs = ms / 1000.0;
    final rate = secs > 0 ? (p.bytesDone / secs).round() : 0;
    final line =
        '[$bar] $pct%  ${_fmt(p.bytesDone)}/${_fmt(p.bytesTotal)}  '
        '${_fmt(rate)}/s  ${_short(p.currentPath)}';
    final pad = _lastLen > line.length ? ' ' * (_lastLen - line.length) : '';
    _out.write('\r$line$pad');
    _lastLen = line.length;
  }

  /// Finishes the bar with a trailing newline (no-op when disabled).
  void finish() {
    if (_enabled) _out.write('\n');
  }

  static String _fmt(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  static String _short(String path, [int max = 28]) {
    if (path.length <= max) return path;
    return '…${path.substring(path.length - max + 1)}';
  }
}

/// A live, multi-line progress view for OmnyDrive sync transfers.
///
/// Draws one in-place progress bar per concurrent file upload/download —
/// `[####----] ↑ path  4.1/6.6 KB` — fed by omnydrive [ProgressEvent]s as their
/// bytes stream, plus a trailing `[##] 71%  5/7 files` overall line. The block
/// is redrawn with ANSI cursor moves, throttled to a few updates a second.
/// Coarse events without per-file data (git push/clone) collapse to a single
/// `pushing…` line. A no-op when stdout is not a terminal (or `NO_COLOR` is
/// set), so piped/redirected output stays clean.
class SyncProgressBar {
  static const int _maxBars = 8;

  final StringSink _out;
  final bool _enabled;
  final int _width;
  final Stopwatch _sw = Stopwatch()..start();
  int _lastRenderMs = -1000;

  // Live state, rebuilt from the event stream.
  final Map<String, _ItemBar> _active = {};
  int _completed = 0;
  int _total = 0;
  String? _coarse; // last coarse phase message (git push/clone)
  int _drawnLines = 0; // height of the block the cursor currently sits below

  /// Creates a sync progress bar writing to [out] (defaults to stdout).
  SyncProgressBar({StringSink? out, bool? enabled, int width = 24})
    : _out = out ?? stdout,
      _width = width,
      _enabled =
          enabled ??
          (stdout.hasTerminal && !Platform.environment.containsKey('NO_COLOR'));

  /// Folds [e] into the live state and redraws, throttled; safe to call on every
  /// event. Item start/complete milestones bypass the throttle so the view never
  /// lags a file appearing or settling.
  void update(ProgressEvent e) {
    if (!_enabled || e.phase == ProgressPhase.done) return;
    _ingest(e);
    final milestone =
        e.itemState == ProgressItemState.started ||
        e.itemState == ProgressItemState.completed;
    final ms = _sw.elapsedMilliseconds;
    if (!milestone && ms - _lastRenderMs < 100) return;
    _lastRenderMs = ms;
    _paint(_compose());
  }

  void _ingest(ProgressEvent e) {
    if (e.total != null) _total = e.total!;
    if (e.completed != null) _completed = e.completed!;
    final path = e.path;
    final state = e.itemState;
    if (path == null || state == null) {
      // Coarse phase event (git push/clone): remember its message, if any.
      if (e.total == null) _coarse = e.message.isEmpty ? null : e.message;
      return;
    }
    _coarse = null;
    switch (state) {
      case ProgressItemState.started:
      case ProgressItemState.progress:
        _active[path] = _ItemBar(
          kind: e.itemKind ?? ProgressItemKind.transferred,
          bytes: e.itemBytes ?? 0,
          totalBytes: e.itemTotalBytes ?? e.itemSize ?? 0,
          size: e.itemSize,
        );
      case ProgressItemState.completed:
        _active.remove(path);
    }
  }

  List<String> _compose() {
    final lines = <String>[];
    var shown = 0;
    for (final entry in _active.entries) {
      if (shown >= _maxBars) {
        lines.add('  …and ${_active.length - shown} more');
        break;
      }
      lines.add(_itemLine(entry.key, entry.value));
      shown++;
    }
    if (_total > 0) lines.add(_overallLine());
    if (lines.isEmpty && _coarse != null) lines.add('  $_coarse…');
    return lines;
  }

  String _itemLine(String path, _ItemBar it) {
    final mark = _kindMark(it.kind);
    final frac = it.totalBytes == 0
        ? 0.0
        : (it.bytes / it.totalBytes).clamp(0.0, 1.0);
    final amount =
        '${ProgressBar._fmt(it.bytes)}/${ProgressBar._fmt(it.totalBytes)}';
    return '  [${_barOf(frac, _width)}] $mark ${ProgressBar._short(path)}'
        '  $amount';
  }

  String _overallLine() {
    final frac = _total == 0 ? 1.0 : (_completed / _total).clamp(0.0, 1.0);
    final pct = (frac * 100).clamp(0, 100).toStringAsFixed(0).padLeft(3);
    return '[${_barOf(frac, _width)}] $pct%  $_completed/$_total files';
  }

  /// Repaints the block in place: rewind to its top, redraw each line (clearing
  /// any stale tail), and reclaim rows when the block shrank.
  void _paint(List<String> lines) {
    if (lines.isEmpty) return;
    final b = StringBuffer();
    if (_drawnLines > 0) b.write('\x1b[${_drawnLines}A');
    for (final line in lines) {
      b.write('\x1b[2K$line\n');
    }
    final extra = _drawnLines - lines.length;
    if (extra > 0) {
      for (var i = 0; i < extra; i++) {
        b.write('\x1b[2K\n');
      }
      b.write('\x1b[${extra}A');
    }
    _out.write(b.toString());
    _drawnLines = lines.length;
  }

  /// Clears the live block and resets state so the bar can be reused across
  /// successive transfers (e.g. a long-running `watch`). The caller then prints
  /// its own final report where the block was.
  void finish() {
    if (_enabled && _drawnLines > 0) {
      final b = StringBuffer('\x1b[${_drawnLines}A');
      for (var i = 0; i < _drawnLines; i++) {
        b.write('\x1b[2K\n');
      }
      b.write('\x1b[${_drawnLines}A');
      _out.write(b.toString());
    }
    _active.clear();
    _completed = 0;
    _total = 0;
    _coarse = null;
    _drawnLines = 0;
    _lastRenderMs = -1000;
  }

  static String _barOf(double frac, int width) {
    final filled = (frac * width).round().clamp(0, width);
    return '#' * filled + '-' * (width - filled);
  }
}

/// A live per-file transfer bar tracked by [SyncProgressBar]. [bytes]/
/// [totalBytes] are on-wire (compressed) figures; [size] is the original size.
class _ItemBar {
  final ProgressItemKind kind;
  final int bytes;
  final int totalBytes;
  final int? size;
  _ItemBar({
    required this.kind,
    required this.bytes,
    required this.totalBytes,
    this.size,
  });
}

String _kindMark(ProgressItemKind kind) => switch (kind) {
  ProgressItemKind.transferred => '↑',
  ProgressItemKind.copied => '≡',
  ProgressItemKind.removed => '✗',
};

/// Formats a sync [ProgressEvent] as a per-path status line for in-session
/// display above the prompt, or `null` when there is nothing useful to show.
///
/// Emits one line per file as it settles — `↑ path (4.1 KB → 1.2 KB wire)` for
/// an upload, `≡ path (deduped)` for a server-side copy, `- path (removed)` for
/// a delete — and `pushing…` for coarse git phases. In-flight `started`/
/// `progress` events and the bulk count event are suppressed (a carriage-return
/// bar would fight the prompt); the terminal `done` phase yields `null`.
String? formatSyncProgress(ProgressEvent e) {
  if (e.phase == ProgressPhase.done) return null;
  final state = e.itemState;
  final path = e.path;
  if (state != null && path != null) {
    if (state != ProgressItemState.completed) return null;
    return _itemSummaryLine(e, path);
  }
  // No per-item info: a coarse git phase message, or the bulk count event (whose
  // detail the per-path lines above already carry).
  if (e.total == null) {
    return e.message.isEmpty ? null : '${e.message}…';
  }
  return null;
}

String _itemSummaryLine(ProgressEvent e, String path) {
  final kind = e.itemKind ?? ProgressItemKind.transferred;
  switch (kind) {
    case ProgressItemKind.transferred:
      final raw = e.itemSize;
      final wire = e.itemTotalBytes;
      final detail = raw == null
          ? ''
          : '  (${ProgressBar._fmt(raw)}'
                '${wire != null && wire < raw ? ' → ${ProgressBar._fmt(wire)} wire' : ''})';
      return '↑ $path$detail';
    case ProgressItemKind.copied:
      return '≡ $path  (deduped)';
    case ProgressItemKind.removed:
      return '- $path  (removed)';
  }
}

/// Builds the final report for a completed sync [o] — a one-line summary of file
/// counts and raw vs on-wire bytes, e.g.
/// `Synced push: 12 transferred, 3 copied · 4.1 MB (1.2 MB on wire).` When
/// [verbose], appends one line per path (`+` transferred, `=` copied, `-`
/// removed). Mirrors the wording of `:drive`/`omnyshell drive` so the CLI and
/// in-session paths read the same.
String formatSyncReport(SyncOutcome o, {bool verbose = false}) {
  if (o.isConflict) return 'Conflict: ${o.conflict!.message}';
  if (o.merged) {
    final parts = <String>[];
    if (o.pushedPaths.isNotEmpty) parts.add('pushed ${o.pushedPaths.length}');
    if (o.pulledPaths.isNotEmpty) parts.add('pulled ${o.pulledPaths.length}');
    final buf = StringBuffer(
      'Merged: ${parts.isEmpty ? 'no changes' : parts.join(', ')}.',
    );
    if (verbose) {
      for (final p in o.pushedPaths) {
        buf.write('\n  → $p');
      }
      for (final p in o.pulledPaths) {
        buf.write('\n  ← $p');
      }
    }
    return buf.toString();
  }
  if (o.direction == null) return 'Already up to date.';

  final counts = <String>[];
  if (o.transferredPaths.isNotEmpty) {
    counts.add('${o.transferredPaths.length} transferred');
  }
  if (o.copiedPaths.isNotEmpty) counts.add('${o.copiedPaths.length} copied');
  if (o.removedPaths.isNotEmpty) counts.add('${o.removedPaths.length} removed');
  // Git syncs expose no per-path metrics; fall back to the applied count.
  final summary = counts.isEmpty ? '${o.applied} change(s)' : counts.join(', ');

  final buf = StringBuffer('Synced ${o.direction!.wireValue}: $summary');
  if (o.bytesTransferred > 0) {
    final raw = ProgressBar._fmt(o.bytesTransferred);
    buf.write(
      o.bytesOnWire > 0 && o.bytesOnWire != o.bytesTransferred
          ? ' · $raw (${ProgressBar._fmt(o.bytesOnWire)} on wire)'
          : ' · $raw',
    );
  }
  if (o.publishedBranch != null) buf.write(' (published ${o.publishedBranch})');
  buf.write('.');

  if (verbose) {
    for (final p in o.transferredPaths) {
      buf.write('\n  + $p');
    }
    for (final p in o.copiedPaths) {
      buf.write('\n  = $p');
    }
    for (final p in o.removedPaths) {
      buf.write('\n  - $p');
    }
  }
  return buf.toString();
}

/// Above this many lines on a side, the inline line diff is skipped (its
/// LCS table is O(n·m)); a one-line summary is shown instead.
const _maxDiffLines = 4000;

/// Renders a [FileDiff] for `omnyshell drive diff`: a size/hash header for each
/// side, then a unified line diff (`-` local, `+` remote) when both sides are
/// small text. Big or binary files fall back to the header alone.
String formatFileDiff(FileDiff d) {
  final buf = StringBuffer()
    ..writeln('diff ${d.path}')
    ..writeln('  local:  ${_sideSummary(d.local)}')
    ..writeln('  remote: ${_sideSummary(d.origin)}');

  if (d.identical) {
    buf.writeln('No differences.');
    return buf.toString();
  }
  if (d.local == null) {
    buf.writeln('Only on remote (node).');
  } else if (d.origin == null) {
    buf.writeln('Only on local.');
  }
  final verdict = _divergenceLine(d.side);
  if (verdict != null) buf.writeln(verdict);
  if (d.tooLarge) {
    buf.writeln('File too large for an inline diff — size/hash only.');
    return buf.toString();
  }
  if (d.binary) {
    buf.writeln('Binary file — size/hash only.');
    return buf.toString();
  }
  if (!d.hasContent) return buf.toString();

  final local = const LineSplitter().convert(
    utf8.decode(d.localBytes ?? const [], allowMalformed: true),
  );
  final origin = const LineSplitter().convert(
    utf8.decode(d.originBytes ?? const [], allowMalformed: true),
  );
  if (local.length > _maxDiffLines || origin.length > _maxDiffLines) {
    buf.writeln(
      'Too many lines for an inline diff '
      '(${local.length} local vs ${origin.length} remote) — size/hash only.',
    );
    return buf.toString();
  }
  buf
    ..writeln('--- local')
    ..writeln('+++ remote');
  for (final line in _lineDiff(local, origin)) {
    buf.writeln(line);
  }
  return buf.toString();
}

String _sideSummary(FileManifestEntry? e) => e == null
    ? 'absent'
    : '${ProgressBar._fmt(e.size)}  ${e.hash.value.substring(0, 12)}…';

/// Renders a [DriveChanges] for `omnyshell drive conflicts`: the diverging paths
/// grouped by which side changed, with true conflicts first. [mountId] tags the
/// header.
String formatDriveChanges(DriveChanges c, {required String mountId}) {
  if (c.isEmpty) return 'mount $mountId: in sync — no differences.';
  final buf = StringBuffer(
    'mount $mountId: ${c.total} diverging path${c.total == 1 ? '' : 's'}',
  );
  void section(String title, List<String> paths, String mark) {
    if (paths.isEmpty) return;
    buf.write('\n$title (${paths.length}):');
    for (final p in paths) {
      buf.write('\n  $mark $p');
    }
  }

  section(
    'conflicts — changed on both sides, resolve before sync',
    c.conflicts,
    '!',
  );
  section('changed only locally — sync will push', c.localOnly, '→');
  section('changed only on the node — sync will pull', c.remoteOnly, '←');
  section('differ — baseline unknown, run a sync to classify', c.unknown, '?');
  // When per-file diffs were requested, render each below the summary
  // (conflicts first, then unclassified paths), separated by a horizontal rule.
  for (final path in [...c.conflicts, ...c.unknown]) {
    final d = c.diffs[path];
    if (d == null) continue;
    buf
      ..write('\n\n')
      ..write(_diffDivider)
      ..write('\n')
      ..write(formatFileDiff(d).trimRight());
  }
  return buf.toString();
}

/// Horizontal rule separating one file's diff from the next.
const _diffDivider =
    '────────────────────────────────────────────────────────────';

/// A one-line verdict explaining which side changed and how a sync reconciles
/// it. Returns null when there is nothing useful to add.
String? _divergenceLine(FileDivergence side) => switch (side) {
  FileDivergence.localOnly => 'Changed only locally — sync will push it.',
  FileDivergence.remoteOnly => 'Changed only on the node — sync will pull it.',
  FileDivergence.bothSides =>
    'Changed on both sides — sync will report a conflict (resolve it).',
  FileDivergence.unknown =>
    'No baseline snapshot yet, so the changed side is unknown — run a sync '
        'while the mount is converged to record one.',
  FileDivergence.none => null,
};

/// A whole-file line diff via longest-common-subsequence backtracking. Common
/// lines are prefixed `  `, local-only `- `, origin-only `+ `.
List<String> _lineDiff(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  // lcs[i][j] = LCS length of a[i..] and b[j..].
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <String>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add('  ${a[i++]}');
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add('- ${a[i++]}');
    } else {
      out.add('+ ${b[j++]}');
    }
  }
  while (i < n) {
    out.add('- ${a[i++]}');
  }
  while (j < m) {
    out.add('+ ${b[j++]}');
  }
  return out;
}
