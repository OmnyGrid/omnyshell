import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// Requested pseudo-terminal geometry for an interactive shell.
///
/// Travels client→hub→node so the node can allocate a real PTY at this geometry
/// (`PtyShellBackend`). When no PTY is available the pipe fallback surfaces the
/// same values via the `TERM`/`COLUMNS`/`LINES` environment variables.
@immutable
class PtySpec {
  /// The terminal type (e.g. `xterm-256color`).
  final String term;

  /// Terminal width in columns.
  final int cols;

  /// Terminal height in rows.
  final int rows;

  /// Creates a PTY spec.
  const PtySpec({required this.term, required this.cols, required this.rows});

  /// A sensible default terminal (80×24, `xterm-256color`).
  static const PtySpec defaults = PtySpec(
    term: 'xterm-256color',
    cols: 80,
    rows: 24,
  );

  /// Returns a copy with new dimensions (used on terminal resize).
  PtySpec resized({required int cols, required int rows}) =>
      PtySpec(term: term, cols: cols, rows: rows);

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {'term': term, 'cols': cols, 'rows': rows};

  /// Decodes from a JSON map.
  static PtySpec fromJson(Map<String, dynamic> json) => PtySpec(
    term: Json.optString(json, 'term') ?? 'xterm-256color',
    cols: Json.optInt(json, 'cols', 80)!,
    rows: Json.optInt(json, 'rows', 24)!,
  );
}
