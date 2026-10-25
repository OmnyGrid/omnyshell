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

  /// The operating system's version/build string (e.g. the kernel release and
  /// build on Linux), or `null` when the node did not report one (older
  /// agents).
  final String? osVersion;

  /// The number of logical processors on the node, or `null` when not reported.
  final int? cpuCount;

  /// The Dart runtime the agent runs on (e.g. `3.13.0 (stable)`), or `null`
  /// when not reported.
  final String? runtimeVersion;

  /// Creates platform info.
  const PlatformInfo({
    required this.os,
    required this.arch,
    required this.agentVersion,
    required this.hostname,
    this.osVersion,
    this.cpuCount,
    this.runtimeVersion,
  });

  /// Serializes to a JSON map. The optional fields are omitted when unknown, so
  /// the wire shape stays identical for agents that do not report them.
  Map<String, dynamic> toJson() => {
    'os': os,
    'arch': arch,
    'agentVersion': agentVersion,
    'hostname': hostname,
    if (osVersion != null) 'osVersion': osVersion,
    if (cpuCount != null) 'cpuCount': cpuCount,
    if (runtimeVersion != null) 'runtimeVersion': runtimeVersion,
  };

  /// Decodes from a JSON map.
  static PlatformInfo fromJson(Map<String, dynamic> json) => PlatformInfo(
    os: Json.requireString(json, 'os'),
    arch: Json.requireString(json, 'arch'),
    agentVersion: Json.optString(json, 'agentVersion') ?? 'unknown',
    hostname: Json.optString(json, 'hostname') ?? 'unknown',
    osVersion: Json.optString(json, 'osVersion'),
    cpuCount: Json.optInt(json, 'cpuCount'),
    runtimeVersion: Json.optString(json, 'runtimeVersion'),
  );
}
