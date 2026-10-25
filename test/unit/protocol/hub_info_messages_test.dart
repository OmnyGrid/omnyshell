import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

void main() {
  late FrameCodec codec;
  setUp(() => codec = FrameCodec.standard());

  T roundTrip<T extends ControlMessage>(T message) {
    final encoded = codec.encodeControl(message);
    final decoded = codec.decodeControl(encoded).message;
    expect(decoded, isA<T>());
    return decoded as T;
  }

  final info = HubInfo(
    hubUid: 'hub_7f3a',
    version: '1.66.0',
    protocolVersion: 2,
    minProtocolVersion: 1,
    platform: const PlatformInfo(
      os: 'linux',
      arch: 'x64',
      agentVersion: '1.66.0',
      hostname: 'hub-eu-1',
      osVersion: '6.1.0-53-cloud-amd64',
      cpuCount: 4,
      runtimeVersion: '3.13.0 (stable)',
    ),
    startedAt: DateTime.utc(2026, 10, 22, 8, 30),
    uptime: const Duration(days: 3, seconds: 5),
    nodes: 5,
    onlineNodes: 4,
    clients: 2,
    sessions: 7,
    tunnels: 1,
    tunnelPorts: '20000-20100',
    aiProvider: 'anthropic',
  );

  test('HubInfoRequest round-trips', () {
    expect(roundTrip(const HubInfoRequest(requestId: 'r1')).requestId, 'r1');
  });

  test('HubInfoResponse round-trips every field', () {
    final out = roundTrip(HubInfoResponse(requestId: 'r2', info: info)).info;
    expect(out.toJson(), info.toJson());
    expect(out.hubUid, 'hub_7f3a');
    expect(out.minProtocolVersion, 1);
    expect(out.platform.cpuCount, 4);
    expect(out.startedAt, DateTime.utc(2026, 10, 22, 8, 30));
    expect(out.uptime, const Duration(days: 3, seconds: 5));
    expect(out.onlineNodes, 4);
    expect(out.tunnelPorts, '20000-20100');
    expect(out.aiProvider, 'anthropic');
  });

  test('a Hub without a UID, tunnels or AI omits them', () {
    final bare = HubInfo(
      version: '1.66.0',
      protocolVersion: 1,
      minProtocolVersion: 1,
      platform: info.platform,
      startedAt: info.startedAt,
      uptime: Duration.zero,
    );
    final json = bare.toJson();
    expect(json.containsKey('hubUid'), isFalse);
    expect(json.containsKey('tunnelPorts'), isFalse);
    expect(json.containsKey('aiProvider'), isFalse);
    final out = HubInfo.fromJson(json);
    expect(out.hubUid, isNull);
    expect(out.tunnelPorts, isNull);
    expect(out.aiProvider, isNull);
  });

  group('AuthOk.hubVersion', () {
    test('round-trips', () {
      final out = roundTrip(
        const AuthOk(
          principal: 'alice',
          displayName: 'Alice',
          roles: ['admin'],
          sessionToken: 't',
          hubVersion: '1.66.0',
        ),
      );
      expect(out.hubVersion, '1.66.0');
    });

    test('is absent from an older Hub, and omitted when null', () {
      const old = AuthOk(
        principal: 'alice',
        displayName: 'Alice',
        roles: [],
        sessionToken: 't',
      );
      expect(old.toJson().containsKey('hubVersion'), isFalse);
      expect(roundTrip(old).hubVersion, isNull);
    });
  });
}
