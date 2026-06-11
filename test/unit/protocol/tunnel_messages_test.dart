import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

void main() {
  late FrameCodec codec;

  setUp(() => codec = FrameCodec.standard());

  T roundTrip<T extends ControlMessage>(T message) =>
      codec.decodeControl(codec.encodeControl(message)).message as T;

  group('tunnel lifecycle messages', () {
    test('round-trips TunnelOpenRequest with an explicit public port', () {
      final decoded = roundTrip(
        const TunnelOpenRequest(
          requestId: 'r1',
          nodeId: 'web-01',
          targetPort: 3000,
          publicPort: 20080,
        ),
      );
      expect(decoded.requestId, 'r1');
      expect(decoded.nodeId, 'web-01');
      expect(decoded.targetHost, 'localhost');
      expect(decoded.targetPort, 3000);
      expect(decoded.publicPort, 20080);
    });

    test('round-trips TunnelOpenRequest without a public port (dynamic)', () {
      final decoded = roundTrip(
        const TunnelOpenRequest(
          requestId: 'r2',
          nodeId: TunnelOpenRequest.localNode,
          targetPort: 8080,
        ),
      );
      expect(decoded.nodeId, '@local');
      expect(decoded.publicPort, isNull);
    });

    test('round-trips TunnelOpened / TunnelRejected', () {
      final opened = roundTrip(
        const TunnelOpened(
          requestId: 'r1',
          tunnelId: 'tid',
          publicHost: '127.0.0.1',
          publicPort: 20080,
        ),
      );
      expect(opened.tunnelId, 'tid');
      expect(opened.publicPort, 20080);

      final rejected = roundTrip(
        const TunnelRejected(
          requestId: 'r1',
          reason: 'port_out_of_range',
          message: 'nope',
        ),
      );
      expect(rejected.reason, 'port_out_of_range');
      expect(rejected.message, 'nope');
    });

    test('round-trips close + list messages, including TunnelInfo', () {
      final close = roundTrip(
        const TunnelCloseRequest(requestId: 'r1', tunnelRef: 'tid'),
      );
      expect(close.tunnelRef, 'tid');

      final list = roundTrip(
        TunnelListResponse(
          requestId: 'r1',
          tunnels: [
            TunnelInfo(
              tunnelId: 'tid',
              nodeId: 'web-01',
              ownerUserId: 'alice',
              targetHost: 'localhost',
              targetPort: 3000,
              publicHost: '127.0.0.1',
              publicPort: 20080,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ],
        ),
      );
      expect(list.tunnels, hasLength(1));
      expect(list.tunnels.single.tunnelId, 'tid');
      expect(list.tunnels.single.publicPort, 20080);
    });
  });

  group('tunnel data-channel messages', () {
    test('round-trips NodeTunnelConnect preserving the channel id', () {
      final connect = NodeTunnelConnect(
        channel: 9,
        tunnelId: 'tid',
        targetHost: '127.0.0.1',
        targetPort: 3000,
        principal: 'alice',
      );
      final encoded = codec.encodeControl(connect);
      final decoded = codec.decodeControl(encoded).message as NodeTunnelConnect;
      expect(decoded.channel, 9);
      expect(decoded.targetPort, 3000);
      expect(decoded.principal, 'alice');
    });

    test('round-trips NodeTunnelConnected / NodeTunnelConnectFailed', () {
      final ok = roundTrip(
        const NodeTunnelConnected(channel: 9, tunnelId: 'tid'),
      );
      expect(ok.channel, 9);

      final failed = roundTrip(
        const NodeTunnelConnectFailed(
          channel: 9,
          tunnelId: 'tid',
          reason: 'dial_failed',
          message: 'refused',
        ),
      );
      expect(failed.reason, 'dial_failed');
      expect(failed.message, 'refused');
    });
  });
}
