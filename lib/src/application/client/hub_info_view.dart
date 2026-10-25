import '../../domain/entities/hub_info.dart';
import '../../version.dart';

/// One titled group of label/value rows describing a Hub.
typedef HubInfoSection = ({String title, List<(String, String)> rows});

/// The sections every Hub view shows — the dashboard's Hub tab,
/// `omnyshell hub info` and the `:hub` local command — so they stay in step.
///
/// [hubUrl] is the address this client dialled and [principal] who it is
/// signed in as; either is left out when unknown. [clientVersion] is compared
/// against the Hub's build.
List<HubInfoSection> hubInfoSections(
  HubInfo info, {
  String? hubUrl,
  String? principal,
  String clientVersion = omnyShellVersion,
}) {
  const notReported = '— (not reported)';
  final p = info.platform;
  final osVersion = p.osVersion;
  final protocol = info.minProtocolVersion == info.protocolVersion
      ? 'v${info.protocolVersion}'
      : 'v${info.protocolVersion} (accepts v${info.minProtocolVersion}+)';
  final tunnelPorts = info.tunnelPorts;
  final aiProvider = info.aiProvider;
  return [
    (
      title: 'Identity',
      rows: [
        if (hubUrl != null) ('URL', hubUrl),
        ('UID', info.hubUid ?? notReported),
        if (principal != null) ('Signed in as', principal),
      ],
    ),
    (
      title: 'System',
      rows: [
        ('OS', p.os),
        (
          'OS version',
          osVersion == null || osVersion.isEmpty ? notReported : osVersion,
        ),
        ('Arch', p.arch),
        ('CPUs', p.cpuCount?.toString() ?? notReported),
        ('Hostname', p.hostname),
      ],
    ),
    (
      title: 'OmnyShell',
      rows: [
        ('Version', hubVersionLabel(info.version, clientVersion)),
        ('Dart runtime', p.runtimeVersion ?? notReported),
        ('Protocol', protocol),
      ],
    ),
    (
      title: 'Activity',
      rows: [
        ('Started', _timestamp(info.startedAt)),
        ('Uptime', formatUptime(info.uptime)),
        ('Nodes', '${info.nodes} (${info.onlineNodes} online)'),
        ('Clients', '${info.clients}'),
        ('Sessions', '${info.sessions}'),
        ('Your tunnels', '${info.tunnels}'),
      ],
    ),
    (
      title: 'Features',
      rows: [
        (
          'Tunnels',
          tunnelPorts == null ? 'disabled' : 'enabled (ports $tunnelPorts)',
        ),
        ('AI default', aiProvider ?? 'none configured'),
      ],
    ),
  ];
}

/// The Hub [version] annotated against this client's [clientVersion].
String hubVersionLabel(String version, String clientVersion) =>
    version == clientVersion
    ? '$version (same as this client)'
    : '$version (this client: $clientVersion)';

/// [sections] as plain text lines for a terminal: a heading per section and
/// aligned `label  value` rows beneath it. Control characters are removed, as
/// the values come from the Hub and are written to the terminal verbatim.
List<String> hubInfoLines(List<HubInfoSection> sections) {
  var labelWidth = 0;
  for (final section in sections) {
    for (final (label, _) in section.rows) {
      if (label.length > labelWidth) labelWidth = label.length;
    }
  }
  final out = <String>[];
  for (final section in sections) {
    if (out.isNotEmpty) out.add('');
    out.add(section.title);
    for (final (label, value) in section.rows) {
      out.add('  ${label.padRight(labelWidth)}  ${_stripControlChars(value)}');
    }
  }
  return out;
}

/// [d] as a compact `3d 4h 12m` (seconds only under a minute).
String formatUptime(Duration d) {
  if (d.isNegative) d = Duration.zero;
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;
  return [
    if (days > 0) '${days}d',
    if (days > 0 || hours > 0) '${hours}h',
    '${minutes}m',
  ].join(' ');
}

/// [t] as `2026-10-25 04:09 UTC`.
String _timestamp(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)} '
      '${two(u.hour)}:${two(u.minute)} UTC';
}

String _stripControlChars(String text) =>
    text.replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), '');
