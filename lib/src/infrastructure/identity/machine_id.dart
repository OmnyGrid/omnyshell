import 'dart:io';

/// Reads a stable, per-machine identifier provided by the operating system.
///
/// This value survives reboots and process restarts (unlike a hostname rename it
/// is keyed to the install/hardware), making it a good stable input for a
/// deterministic node/hub UID:
///
/// * **Linux** — `/etc/machine-id` (falling back to `/var/lib/dbus/machine-id`).
/// * **macOS** — the `IOPlatformUUID` reported by `ioreg`.
/// * **Windows** — `MachineGuid` under `HKLM\SOFTWARE\Microsoft\Cryptography`.
///
/// Returns an empty string when no identifier can be obtained, so UID
/// computation degrades gracefully rather than failing. The result is always
/// trimmed and lower-cased for stability across platforms.
class MachineId {
  const MachineId._();

  /// Resolves the machine id for the current platform, or `''` if unavailable.
  static String read() {
    try {
      if (Platform.isLinux) return _linux();
      if (Platform.isMacOS) return _macOS();
      if (Platform.isWindows) return _windows();
    } on Object {
      // Best-effort only — fall through to empty.
    }
    return '';
  }

  static String _linux() {
    for (final path in const ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
      final file = File(path);
      if (file.existsSync()) {
        final value = file.readAsStringSync().trim();
        if (value.isNotEmpty) return value.toLowerCase();
      }
    }
    return '';
  }

  static String _macOS() {
    final result = Process.runSync('ioreg', [
      '-rd1',
      '-c',
      'IOPlatformExpertDevice',
    ]);
    if (result.exitCode != 0) return '';
    final match = RegExp(
      r'"IOPlatformUUID"\s*=\s*"([^"]+)"',
    ).firstMatch(result.stdout as String);
    return (match?.group(1) ?? '').trim().toLowerCase();
  }

  static String _windows() {
    final result = Process.runSync('reg', [
      'query',
      r'HKLM\SOFTWARE\Microsoft\Cryptography',
      '/v',
      'MachineGuid',
    ]);
    if (result.exitCode != 0) return '';
    final match = RegExp(
      r'MachineGuid\s+REG_SZ\s+([A-Fa-f0-9-]+)',
    ).firstMatch(result.stdout as String);
    return (match?.group(1) ?? '').trim().toLowerCase();
  }
}
