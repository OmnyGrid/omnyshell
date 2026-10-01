/// Parsing and formatting of human-friendly sizes and durations for CLI flags.
library;

/// One mebibyte.
const int mib = 1024 * 1024;

/// Parses a byte size: a plain number of bytes, or a number with a binary unit
/// `K`/`KB`/`KiB`, `M`/`MB`/`MiB`, `G`/`GB`/`GiB` (case-insensitive, all
/// powers of 1024; a fraction such as `1.5M` is allowed). Returns `null` for
/// malformed or negative input.
int? parseByteSize(String raw) {
  final m = RegExp(
    r'^(\d+(?:\.\d+)?)\s*([kmg]?)(?:i?b)?$',
  ).firstMatch(raw.trim().toLowerCase());
  if (m == null) return null;
  final n = double.parse(m.group(1)!);
  final factor = switch (m.group(2)!) {
    'k' => 1024,
    'm' => mib,
    'g' => 1024 * mib,
    _ => 1,
  };
  return (n * factor).round();
}

/// Formats [bytes] compactly in binary units: `512 B`, `1.5 KiB`, `32 MiB`.
String formatByteSize(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final text = u == 0 || v == v.roundToDouble()
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(1);
  return '$text ${units[u]}';
}

/// Parses a duration like `250ms`, `30s`, `5m`, `2h`, `1d`, or `0` (zero).
/// Returns `null` for malformed input.
Duration? parseDurationArg(String raw) {
  final s = raw.trim().toLowerCase();
  if (s == '0') return Duration.zero;
  final m = RegExp(r'^(\d+)(ms|s|m|h|d)$').firstMatch(s);
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)!) {
    'ms' => Duration(milliseconds: n),
    's' => Duration(seconds: n),
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    _ => Duration(days: n),
  };
}

/// Formats [d] compactly with its largest whole unit: `250ms`, `30s`, `5m`,
/// `2h`, `1d`, or `0`.
String formatDurationArg(Duration d) {
  final ms = d.inMilliseconds;
  if (ms == 0) return '0';
  if (ms % Duration.millisecondsPerDay == 0) {
    return '${ms ~/ Duration.millisecondsPerDay}d';
  }
  if (ms % Duration.millisecondsPerHour == 0) {
    return '${ms ~/ Duration.millisecondsPerHour}h';
  }
  if (ms % Duration.millisecondsPerMinute == 0) {
    return '${ms ~/ Duration.millisecondsPerMinute}m';
  }
  if (ms % Duration.millisecondsPerSecond == 0) {
    return '${ms ~/ Duration.millisecondsPerSecond}s';
  }
  return '${ms}ms';
}
