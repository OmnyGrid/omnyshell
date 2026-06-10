import 'dart:io';

/// A best-effort snapshot of what a shell process is currently doing: the
/// foreground command (if any) and the working directory.
class ProcessSnapshot {
  /// The current foreground command line, or `null` when the shell is sitting
  /// at its prompt (or the foreground process could not be determined).
  final String? command;

  /// The current working directory, or `null` when it could not be resolved.
  final String? cwd;

  /// Creates a process snapshot.
  const ProcessSnapshot({this.command, this.cwd});

  /// An empty snapshot (nothing could be determined).
  static const ProcessSnapshot empty = ProcessSnapshot();
}

/// Inspects the OS, by [shellPid], for the shell's current foreground command
/// and working directory. Best-effort and read-only: it shells out to `ps`
/// (and `lsof` on macOS) / reads `/proc` on Linux, returning [ProcessSnapshot]
/// fields as `null` on any unsupported platform or failure. Never throws.
///
/// The foreground command is found via the controlling terminal: the process
/// group flagged `+` by `ps` is the one in the foreground. When only the shell
/// itself is foreground, [ProcessSnapshot.command] is `null` (at the prompt).
Future<ProcessSnapshot> inspectProcess(int shellPid) async {
  if (!Platform.isLinux && !Platform.isMacOS) return ProcessSnapshot.empty;
  try {
    final tty = await _ttyOf(shellPid);
    final foreground = tty == null
        ? null
        : await _foregroundLeader(tty, shellPid);
    // Resolve cwd of the foreground command when present, else of the shell.
    final cwd = await _cwdOf(foreground?.pid ?? shellPid);
    return ProcessSnapshot(command: foreground?.command, cwd: cwd);
  } catch (_) {
    return ProcessSnapshot.empty;
  }
}

class _Proc {
  final int pid;
  final String command;
  const _Proc(this.pid, this.command);
}

/// The controlling terminal of [pid] (e.g. `ttys003`, `pts/3`), or `null` when
/// the process has none.
Future<String?> _ttyOf(int pid) async {
  final r = await Process.run('ps', ['-o', 'tty=', '-p', '$pid']);
  if (r.exitCode != 0) return null;
  final tty = (r.stdout as String).trim();
  if (tty.isEmpty || tty == '?' || tty == '??' || tty == '-') return null;
  return tty;
}

/// The foreground-process-group leader on [tty] that is not the shell itself,
/// or `null` when only the shell occupies the foreground (i.e. at the prompt).
Future<_Proc?> _foregroundLeader(String tty, int shellPid) async {
  final r = await Process.run('ps', [
    '-t',
    tty,
    '-o',
    'pid=,pgid=,stat=,command=',
  ]);
  if (r.exitCode != 0) return null;
  _Proc? best;
  int? bestPid;
  for (final raw in (r.stdout as String).split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 4) continue;
    final pid = int.tryParse(parts[0]);
    final stat = parts[2];
    if (pid == null || pid == shellPid) continue;
    // `+` in the stat flags marks a process in the foreground process group.
    if (!stat.contains('+')) continue;
    final command = parts.sublist(3).join(' ');
    // Prefer the lowest pid in the foreground group (closest to the leader).
    if (bestPid == null || pid < bestPid) {
      bestPid = pid;
      best = _Proc(pid, command);
    }
  }
  return best;
}

/// The working directory of [pid], or `null` when it cannot be resolved.
Future<String?> _cwdOf(int pid) async {
  if (Platform.isLinux) {
    try {
      final link = Link('/proc/$pid/cwd');
      final target = await link.target();
      return target.isEmpty ? null : target;
    } catch (_) {
      return null;
    }
  }
  // macOS: lsof reports the cwd descriptor; `-Fn` prints it on an `n` line.
  final r = await Process.run('lsof', ['-a', '-p', '$pid', '-d', 'cwd', '-Fn']);
  if (r.exitCode != 0) return null;
  for (final line in (r.stdout as String).split('\n')) {
    if (line.startsWith('n')) {
      final path = line.substring(1).trim();
      if (path.isNotEmpty) return path;
    }
  }
  return null;
}
