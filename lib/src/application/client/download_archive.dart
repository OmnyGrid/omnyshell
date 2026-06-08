/// Helpers for the `:download` command's optional compression: turning a remote
/// file or directory into a single `.zip`, `.gz`, or `.tar.gz` archive on the
/// node before transferring it.
///
/// The archive is built on the **remote** side (so only the compressed bytes are
/// transferred) by running [remoteArchiveCommand] as a one-off `exec`. These
/// functions are pure (no I/O) so they can be unit-tested, including by executing
/// the generated snippet in a local `sh`.
library;

/// A supported download archive format.
enum ArchiveFormat { zip, gz, tarGz }

/// Parses a `--…` compression flag into an [ArchiveFormat], or `null` if [arg]
/// is not a recognised compression flag.
ArchiveFormat? parseArchiveFlag(String arg) {
  switch (arg) {
    case '--zip':
      return ArchiveFormat.zip;
    case '--gz':
    case '--gzip':
      return ArchiveFormat.gz;
    case '--tar.gz':
    case '--tgz':
    case '--targz':
      return ArchiveFormat.tarGz;
    default:
      return null;
  }
}

/// The file extension (without a leading dot) for [format].
String archiveExtension(ArchiveFormat format) => switch (format) {
  ArchiveFormat.zip => 'zip',
  ArchiveFormat.gz => 'gz',
  ArchiveFormat.tarGz => 'tar.gz',
};

/// Validates [format] against whether the source [isDir], returning an error
/// message to show the user, or `null` when the combination is allowed.
///
/// A file may be compressed as `.gz` or `.zip`; a directory as `.tar.gz` or
/// `.zip`. `gzip` cannot bundle a directory, and `.tar.gz` is not offered for a
/// single file.
String? archiveError(ArchiveFormat format, {required bool isDir}) {
  if (isDir && format == ArchiveFormat.gz) {
    return 'gzip cannot archive a directory; use --tar.gz or --zip';
  }
  if (!isDir && format == ArchiveFormat.tarGz) {
    return 'use --gz or --zip for a single file';
  }
  return null;
}

/// Returns a POSIX `sh` command that builds an archive of [src] (a file or
/// directory per [isDir]) in [format] and prints the resulting temporary
/// archive path as its only stdout line.
///
/// A temporary output path is created before archiving:
///
/// - First, `mktemp` is used when available, producing a unique path such as
///   `/tmp/tmp.ABc123XYZ`.
/// - If `mktemp` is unavailable, a fallback path is constructed from
///   `${TMPDIR:-/tmp}` and the current shell PID, for example:
///   `/tmp/omnyshell-dl.12345`.
///
/// The archive is written directly to that path and no filename extension is
/// added. For example:
///
/// ```text
/// src = /home/alice/project
/// tmp = /tmp/tmp.ABc123XYZ
/// ```
///
/// With `ArchiveFormat.tarGz`, the resulting file at
/// `/tmp/tmp.ABc123XYZ` contains a gzip-compressed tar archive of
/// `project/`.
///
/// On success, the command prints the temporary archive path and exits with
/// status 0. On failure, the temporary file is removed and the command exits
/// with a non-zero status.
///
/// `src` is embedded as a single-quoted literal. Caller is expected to have
/// validated the combination with [archiveError].
String remoteArchiveCommand(
  String src, {
  required ArchiveFormat format,
  required bool isDir,
}) {
  final archiver = switch ((format, isDir)) {
    // gzip a single file in place to the temp file.
    (ArchiveFormat.gz, _) => r'gzip -c -- "$src" > "$tmp"',
    // tar+gzip a directory, relative to its parent so the dir name is preserved.
    (ArchiveFormat.tarGz, _) =>
      r'tar -czf "$tmp" -C "$(dirname "$src")" -- "$(basename "$src")"',
    // zip a directory recursively (cd into the parent to keep relative paths).
    // `zip` rejects a `--` separator, so it is omitted.
    (ArchiveFormat.zip, true) =>
      r'( cd "$(dirname "$src")" && zip -r -q "$tmp" "$(basename "$src")" )',
    // zip a single file, junking the path so only the basename is stored.
    (ArchiveFormat.zip, false) => r'zip -j -q "$tmp" "$src"',
  };
  final quoted = _singleQuote(src);
  return "src=$quoted; "
      "tmp=\$(mktemp 2>/dev/null) || tmp=\"\${TMPDIR:-/tmp}/omnyshell-dl.\$\$\"; "
      "rm -f \"\$tmp\"; "
      "if $archiver; then printf '%s\\n' \"\$tmp\"; "
      "else rm -f \"\$tmp\"; exit 1; fi";
}

/// Quotes [s] as a single shell word so it is taken literally.
String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
