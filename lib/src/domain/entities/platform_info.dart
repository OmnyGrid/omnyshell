import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// Describes the operating system and architecture a node runs on, advertised
/// to clients during discovery and shown by the `:info` local command.
@immutable
class PlatformInfo {
  /// The operating system name (e.g. `linux`, `macos`, `windows`).
  final String os;

  /// The processor architecture (e.g. `x64`, `arm64`).
  final String arch;

  /// The node agent version string — the OmnyShell build the node reports it is
  /// running (see [omnyShellVersion]); the Hub reports the sentinel `'hub'`.
  final String agentVersion;

  /// The node's hostname.
  final String hostname;

  /// Creates platform info.
  const PlatformInfo({
    required this.os,
    required this.arch,
    required this.agentVersion,
    required this.hostname,
  });

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'os': os,
    'arch': arch,
    'agentVersion': agentVersion,
    'hostname': hostname,
  };

  /// Decodes from a JSON map.
  static PlatformInfo fromJson(Map<String, dynamic> json) => PlatformInfo(
    os: Json.requireString(json, 'os'),
    arch: Json.requireString(json, 'arch'),
    agentVersion: Json.optString(json, 'agentVersion') ?? 'unknown',
    hostname: Json.optString(json, 'hostname') ?? 'unknown',
  );
}
