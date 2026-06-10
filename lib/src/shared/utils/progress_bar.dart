import 'dart:io';

import 'package:omnydrive/omnydrive.dart' show ProgressEvent, ProgressPhase;

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

/// A single-line, carriage-return progress bar for OmnyDrive sync transfers.
///
/// Renders `[######----] 71%  5/7 files  path` in place from omnydrive
/// [ProgressEvent]s as each file is uploaded/downloaded, throttled to a few
/// updates a second. Coarse events without a file count (git push/clone) show
/// their phase message instead (e.g. `pushing…`). A no-op when stdout is not a
/// terminal (or `NO_COLOR` is set), so piped/redirected output stays clean.
class SyncProgressBar {
  final StringSink _out;
  final bool _enabled;
  final int _width;
  final Stopwatch _sw = Stopwatch()..start();
  int _lastLen = 0;
  int _lastRenderMs = -1000;
  bool _dirty = false;

  /// Creates a sync progress bar writing to [out] (defaults to stdout).
  SyncProgressBar({StringSink? out, bool? enabled, int width = 24})
    : _out = out ?? stdout,
      _width = width,
      _enabled =
          enabled ??
          (stdout.hasTerminal && !Platform.environment.containsKey('NO_COLOR'));

  /// Renders [e], throttled; safe to call on every event. The terminal `done`
  /// phase is left for [finish] to terminate, preserving the last drawn line.
  void update(ProgressEvent e) {
    if (!_enabled || e.phase == ProgressPhase.done) return;
    final line = _render(e);
    if (line == null) return;
    final last = e.total != null && e.completed == e.total;
    final ms = _sw.elapsedMilliseconds;
    if (!last && ms - _lastRenderMs < 100) return;
    _lastRenderMs = ms;
    _dirty = true;
    final pad = _lastLen > line.length ? ' ' * (_lastLen - line.length) : '';
    _out.write('\r$line$pad');
    _lastLen = line.length;
  }

  String? _render(ProgressEvent e) {
    final total = e.total;
    final completed = e.completed;
    if (total == null || completed == null) {
      // Coarse phase event (git push/clone): show its message, if any.
      return e.message.isEmpty ? null : '  ${e.message}…';
    }
    if (total == 0) return null; // nothing to transfer
    final frac = (completed / total).clamp(0.0, 1.0);
    final pct = (frac * 100).clamp(0, 100).toStringAsFixed(0).padLeft(3);
    final filled = (frac * _width).round().clamp(0, _width);
    final bar = '#' * filled + '-' * (_width - filled);
    final path = e.message.isEmpty ? '' : '  ${ProgressBar._short(e.message)}';
    return '[$bar] $pct%  $completed/$total files$path';
  }

  /// Finishes the current bar line with a trailing newline (no-op when disabled
  /// or nothing was drawn since the last finish). Resets state so the bar can be
  /// reused across successive transfers, e.g. a long-running `watch`.
  void finish() {
    if (_enabled && _dirty) _out.write('\n');
    _dirty = false;
    _lastLen = 0;
  }
}

/// Formats a sync [ProgressEvent] as a compact one-line status for in-session
/// display above the prompt, or `null` when there is nothing useful to show.
///
/// Returns `syncing 5/7: path` for per-file directory progress and `pushing…`
/// for coarse git phases; the terminal `done` phase yields `null` (callers
/// print their own final summary).
String? formatSyncProgress(ProgressEvent e) {
  if (e.phase == ProgressPhase.done) return null;
  final total = e.total;
  final completed = e.completed;
  if (total == null || completed == null) {
    return e.message.isEmpty ? null : '${e.message}…';
  }
  if (total == 0) return null;
  final path = e.message.isEmpty ? '' : ': ${e.message}';
  return 'syncing $completed/$total$path';
}
