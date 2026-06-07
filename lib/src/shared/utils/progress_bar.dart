import 'dart:io';

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
