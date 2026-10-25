import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/src/application/client/hub_info_view.dart';
import 'package:test/test.dart';

void main() {
  HubInfo info({int protocol = 1, int minProtocol = 1}) => HubInfo(
    version: '1.66.0',
    protocolVersion: protocol,
    minProtocolVersion: minProtocol,
    platform: const PlatformInfo(
      os: 'macos',
      arch: 'arm64',
      agentVersion: '1.66.0',
      hostname: 'mini',
    ),
    startedAt: DateTime.utc(2026, 1, 2, 3, 4),
    uptime: const Duration(minutes: 1),
  );

  group('formatUptime', () {
    test('drops leading zero units but keeps minutes', () {
      expect(formatUptime(const Duration(seconds: 42)), '42s');
      expect(formatUptime(const Duration(minutes: 7)), '7m');
      expect(formatUptime(const Duration(hours: 2)), '2h 0m');
      expect(formatUptime(const Duration(days: 1, minutes: 5)), '1d 0h 5m');
      expect(formatUptime(const Duration(seconds: -3)), '0s');
    });
  });

  test('hubVersionLabel compares against the client', () {
    expect(hubVersionLabel('1.66.0', '1.66.0'), '1.66.0 (same as this client)');
    expect(hubVersionLabel('1.67.0', '1.66.0'), '1.67.0 (this client: 1.66.0)');
  });

  test('the protocol row shows the accepted range only when it differs', () {
    String protocol(HubInfo i) => hubInfoSections(
      i,
    ).expand((s) => s.rows).firstWhere((r) => r.$1 == 'Protocol').$2;
    expect(protocol(info()), 'v1');
    expect(protocol(info(protocol: 2)), 'v2 (accepts v1+)');
  });

  test('URL and principal rows appear only when known', () {
    final bare = hubInfoSections(info()).first.rows.map((r) => r.$1);
    expect(bare, ['UID']);
    final full = hubInfoSections(
      info(),
      hubUrl: 'wss://h',
      principal: 'Alice',
    ).first.rows.map((r) => r.$1);
    expect(full, ['URL', 'UID', 'Signed in as']);
  });

  test('hubInfoLines aligns labels and blank-separates sections', () {
    final lines = hubInfoLines([
      (title: 'A', rows: [('x', '1'), ('long', '2')]),
      (title: 'B', rows: [('y', '3')]),
    ]);
    expect(lines, ['A', '  x     1', '  long  2', '', 'B', '  y     3']);
  });
}
