/// Captures the `PATH` a user's shell rc (`~/.zshrc`, `~/.bash_profile`, ...)
/// produces, so a node can carry it into its (otherwise rc-less) sessions.
///
/// The shell is run as a **login + interactive** shell so it sources the same
/// files a normal terminal would, and `PATH` is printed between unique markers
/// so any banner the rc emits is ignored.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _startMarker = '<<OMNYPATH>>';
const _endMarker = '<<ENDPATH>>';

/// Runs [shell] as a login+interactive shell and returns the `PATH` it exports,
/// or `null` on Windows, when `script`/the shell fails, on timeout, or when the
/// markers are missing.
Future<String?> captureLoginPath({
  required String shell,
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (Platform.isWindows) return null;

  Process process;
  try {
    process = await Process.start(shell, [
      '-l',
      '-i',
      '-c',
      'printf "$_startMarker%s$_endMarker" "\$PATH"',
    ], runInShell: false);
  } on Object {
    return null;
  }

  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  // Drain stderr so the child does not block on a full pipe.
  unawaited(process.stderr.drain<void>());

  Timer? killer;
  killer = Timer(timeout, () => process.kill(ProcessSignal.sigkill));
  try {
    final exitCode = await process.exitCode;
    final out = await stdoutFuture;
    killer.cancel();
    if (exitCode != 0 && !out.contains(_startMarker)) return null;
    return _extract(out);
  } on Object {
    killer.cancel();
    return null;
  }
}

/// Extracts the captured PATH between the markers, or `null` if absent/empty.
String? _extract(String output) {
  final start = output.indexOf(_startMarker);
  if (start < 0) return null;
  final from = start + _startMarker.length;
  final end = output.indexOf(_endMarker, from);
  if (end < 0) return null;
  final path = output.substring(from, end).trim();
  return path.isEmpty ? null : path;
}

/// Best-effort rc file path shown to the user for [shell] (display only).
String rcFileFor(String shell) {
  final name = shell.split(Platform.pathSeparator).last.toLowerCase();
  if (name.contains('zsh')) return '~/.zshrc';
  if (name.contains('bash')) return '~/.bashrc';
  if (name.contains('fish')) return '~/.config/fish/config.fish';
  return '~/.profile';
}

/// The difference between an old and new `PATH`, for the confirmation prompt.
class PathDiff {
  /// Entries present in the new PATH but not the old one (order preserved).
  final List<String> added;

  /// Entries present in the old PATH but not the new one (order preserved).
  final List<String> removed;

  /// Whether the new PATH differs from the old (a `null` old counts as changed).
  final bool changed;

  const PathDiff(this.added, this.removed, this.changed);
}

/// Computes the [PathDiff] between [oldPath] (may be `null`) and [newPath].
PathDiff pathDiff(String? oldPath, String newPath) {
  final oldEntries = _entries(oldPath);
  final newEntries = _entries(newPath);
  final oldSet = oldEntries.toSet();
  final newSet = newEntries.toSet();
  final added = newEntries.where((e) => !oldSet.contains(e)).toList();
  final removed = oldEntries.where((e) => !newSet.contains(e)).toList();
  return PathDiff(added, removed, oldPath == null || oldPath != newPath);
}

List<String> _entries(String? path) {
  if (path == null || path.isEmpty) return const [];
  return path.split(':').where((e) => e.isNotEmpty).toList();
}
