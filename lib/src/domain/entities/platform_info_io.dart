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
  );

  static String _architecture() {
    final version = Platform.version;
    final match = RegExp(r'"([^"]+)"').firstMatch(version);
    final target = match?.group(1) ?? '';
    final parts = target.split('_');
    return parts.length >= 2 ? parts.sublist(1).join('_') : 'unknown';
  }
}
