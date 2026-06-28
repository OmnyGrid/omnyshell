/// Browser-safe helpers for working with remote paths and sizes, shared by the
/// local `:` commands (tree, download, upload). Pure Dart — no `dart:io` — so
/// they compile to JavaScript for the web client.
library;

/// Resolves a possibly-relative remote [path] against the live remote [cwd].
///
/// Absolute POSIX paths (`/…`, `~…`) and Windows drive paths (`C:\…`) are
/// returned unchanged; a relative path is joined onto [cwd] when it is known.
String resolveRemotePath(String path, {required String? cwd}) {
  if (path.startsWith('/') || path.startsWith('~')) return path;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) return path; // Windows abs
  if (cwd == null || cwd.isEmpty || cwd == '?') return path;
  final base = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
  return '$base/$path';
}

/// Quotes [s] as a single shell word so it is taken literally on the node.
String shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// The last path segment of a remote [path] (trailing slashes stripped), used to
/// name a downloaded archive; falls back to `archive` for a root/empty path.
String remoteBasename(String path) {
  var p = path;
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  final i = p.lastIndexOf('/');
  final base = i < 0 ? p : p.substring(i + 1);
  return base.isEmpty ? 'archive' : base;
}

/// Formats a byte count as a human-readable size (B, KB, MB, …).
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}
