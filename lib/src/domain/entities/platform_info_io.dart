import 'dart:io';

import 'platform_info.dart';

/// Native (`dart:io`) helpers for [PlatformInfo].
///
/// The `.local()` capture lives here rather than on [PlatformInfo] itself so
/// that the entity stays free of `dart:io` and can be compiled to the browser
/// (the web client only ever decodes platform info from the wire, never
/// captures it). Hub and Node — which always run on the VM — use this.
extension PlatformInfoLocal on PlatformInfo {
  /// Captures the platform of the current process.
  static PlatformInfo local({required String agentVersion}) => PlatformInfo(
    os: Platform.operatingSystem,
    arch: _architecture(),
    agentVersion: agentVersion,
    hostname: Platform.localHostname,
    osVersion: Platform.operatingSystemVersion.trim(),
    cpuCount: Platform.numberOfProcessors,
    runtimeVersion: runtimeVersion(Platform.version),
  );

  /// The Dart version from a `Platform.version` string, without the trailing
  /// build date and target (`3.13.0 (stable) (Wed …) on "linux_x64"` →
  /// `3.13.0 (stable)`).
  static String runtimeVersion(String version) {
    final match = RegExp(r'^\S+(?: \([a-z]+\))?').firstMatch(version.trim());
    return match?.group(0) ?? version.trim();
  }

  static String _architecture() {
    final version = Platform.version;
    final match = RegExp(r'"([^"]+)"').firstMatch(version);
    final target = match?.group(1) ?? '';
    final parts = target.split('_');
    return parts.length >= 2 ? parts.sublist(1).join('_') : 'unknown';
  }
}
