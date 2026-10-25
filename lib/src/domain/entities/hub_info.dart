import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';
import 'platform_info.dart';

/// What a Hub reports about itself to an authenticated client: its identity,
/// build, the machine it runs on, and a snapshot of its activity. Shown by the
/// dashboard's Hub tab, `omnyshell hub info` and the `:hub` local command.
///
/// Only ever sent after authentication (never in the pre-auth `hello`), so an
/// unauthenticated peer cannot use it to fingerprint the Hub.
@immutable
class HubInfo {
  /// The Hub's deterministic UID, or `null` when it runs without one.
  final String? hubUid;

  /// The OmnyShell build the Hub runs (see `omnyShellVersion`).
  final String version;

  /// The wire protocol version the Hub implements.
  final int protocolVersion;

  /// The lowest wire protocol version the Hub accepts.
  final int minProtocolVersion;

  /// The machine the Hub runs on. Its [PlatformInfo.agentVersion] is
  /// [version].
  final PlatformInfo platform;

  /// When the Hub started (UTC).
  final DateTime startedAt;

  /// How long the Hub has been running, measured on the Hub's own clock so a
  /// skewed client clock cannot distort it.
  final Duration uptime;

  /// Nodes registered with the Hub.
  final int nodes;

  /// Of [nodes], those currently online.
  final int onlineNodes;

  /// Authenticated client connections (including the caller's).
  final int clients;

  /// Sessions currently routed through the Hub.
  final int sessions;

  /// Tunnels the caller owns.
  final int tunnels;

  /// The public port range tunnels may bind (e.g. `20000-20100`), or `null`
  /// when tunneling is disabled on this Hub.
  final String? tunnelPorts;

  /// The Hub's default AI provider (e.g. `anthropic`), which clients without
  /// their own key use through the Hub; `null` when none is configured.
  final String? aiProvider;

  /// Creates hub info.
  const HubInfo({
    required this.version,
    required this.protocolVersion,
    required this.minProtocolVersion,
    required this.platform,
    required this.startedAt,
    required this.uptime,
    this.hubUid,
    this.nodes = 0,
    this.onlineNodes = 0,
    this.clients = 0,
    this.sessions = 0,
    this.tunnels = 0,
    this.tunnelPorts,
    this.aiProvider,
  });

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    if (hubUid != null) 'hubUid': hubUid,
    'version': version,
    'protocolVersion': protocolVersion,
    'minProtocolVersion': minProtocolVersion,
    'platform': platform.toJson(),
    'startedAt': startedAt.toUtc().toIso8601String(),
    'uptimeSeconds': uptime.inSeconds,
    'nodes': nodes,
    'onlineNodes': onlineNodes,
    'clients': clients,
    'sessions': sessions,
    'tunnels': tunnels,
    if (tunnelPorts != null) 'tunnelPorts': tunnelPorts,
    if (aiProvider != null) 'aiProvider': aiProvider,
  };

  /// Decodes from a JSON map.
  static HubInfo fromJson(Map<String, dynamic> json) => HubInfo(
    hubUid: Json.optString(json, 'hubUid'),
    version: Json.requireString(json, 'version'),
    protocolVersion: Json.requireInt(json, 'protocolVersion'),
    minProtocolVersion: Json.optInt(json, 'minProtocolVersion', 1)!,
    platform: PlatformInfo.fromJson(
      Json.asObject(json['platform'], 'platform'),
    ),
    startedAt: Json.requireTimestamp(json, 'startedAt'),
    uptime: Duration(seconds: Json.optInt(json, 'uptimeSeconds', 0)!),
    nodes: Json.optInt(json, 'nodes', 0)!,
    onlineNodes: Json.optInt(json, 'onlineNodes', 0)!,
    clients: Json.optInt(json, 'clients', 0)!,
    sessions: Json.optInt(json, 'sessions', 0)!,
    tunnels: Json.optInt(json, 'tunnels', 0)!,
    tunnelPorts: Json.optString(json, 'tunnelPorts'),
    aiProvider: Json.optString(json, 'aiProvider'),
  );
}
