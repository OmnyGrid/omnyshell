import 'dart:async';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/src/infrastructure/transport/frame_connection.dart';
import 'package:omnyshell/src/infrastructure/transport/ws_server_endpoint.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// End-to-end wire-fidelity for the omnyhub-backed [FrameConnection] over a real
/// `wss` socket.
///
/// The unit test drives a fake connection, so it never proves that control
/// frames actually cross the wire as WebSocket **text** frames and data frames
/// as **binary** frames — the one thing that would silently corrupt every
/// session if omnyhub's transport got it wrong. This binds a real TLS
/// [WsServerEndpoint], dials it with [FrameConnection.connect], and asserts the
/// frames survive the round trip byte-for-byte in both directions.
void main() {
  late WsServerEndpoint server;
  late FrameConnection client;
  late OmnyShellConnection accepted;

  setUp(() async {
    final acceptedC = Completer<OmnyShellConnection>();
    server = await WsServerEndpoint.bind(
      host: '127.0.0.1',
      port: 0,
      securityContext: hubSecurityContext(),
      onConnection: (c) {
        if (!acceptedC.isCompleted) acceptedC.complete(c);
      },
    );
    client = await FrameConnection.connect(
      Uri.parse('wss://127.0.0.1:${server.port}'),
      securityContext: trustContext(),
      onBadCertificate: (cert, host, port) => true,
    );
    accepted = await acceptedC.future;
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  test('a control frame crosses the wire as a text frame', () async {
    final received = accepted.incoming.first;
    client.send(
      const ControlFrame(
        Hello(role: 'node', protocolVersion: 1, minVersion: 1, nonce: 'wire'),
      ),
    );

    final frame = await received.timeout(const Duration(seconds: 5));
    expect(frame, isA<ControlFrame>());
    expect(((frame as ControlFrame).message as Hello).nonce, 'wire');
  });

  test('a data frame with non-UTF-8 bytes survives byte-for-byte', () async {
    // Bytes that are NOT valid UTF-8: if omnyhub ever sent this as a text frame
    // it would be mangled by UTF-8 transcoding. This is the core regression.
    final payload = Uint8List.fromList([0xFF, 0x00, 0xFE, 0x80, 0x01, 0xC0]);
    final received = accepted.incoming.first;
    client.send(
      DataFrame(opcode: DataOpcode.stdout, channel: 5, payload: payload),
    );

    final frame = await received.timeout(const Duration(seconds: 5));
    expect(frame, isA<DataFrame>());
    final data = frame as DataFrame;
    expect(data.opcode, DataOpcode.stdout);
    expect(data.channel, 5);
    expect(data.payload, orderedEquals(payload));
  });

  test('the server can push a data frame back to the client', () async {
    final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
    final received = client.incoming.first;
    accepted.send(
      DataFrame(opcode: DataOpcode.stderr, channel: 9, payload: payload),
    );

    final frame = await received.timeout(const Duration(seconds: 5));
    expect(frame, isA<DataFrame>());
    expect((frame as DataFrame).opcode, DataOpcode.stderr);
    expect(frame.payload, orderedEquals(payload));
  });

  test('a large binary payload round-trips intact', () async {
    // Just under the protocol's 64 KiB per-frame cap: a real multi-KB binary
    // frame across the socket, covering every byte value.
    final payload = Uint8List(60 * 1024);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (i * 31 + 7) & 0xFF;
    }
    final received = accepted.incoming.first;
    client.send(
      DataFrame(opcode: DataOpcode.stdout, channel: 1, payload: payload),
    );

    final frame = await received.timeout(const Duration(seconds: 10));
    expect((frame as DataFrame).payload, orderedEquals(payload));
  });

  test(
    'control and data frames interleave without cross-contamination',
    () async {
      final frames = <OmnyShellFrame>[];
      final sub = accepted.incoming.listen(frames.add);

      client.send(
        const ControlFrame(
          Hello(role: 'node', protocolVersion: 1, minVersion: 1, nonce: 'a'),
        ),
      );
      client.send(
        DataFrame(
          opcode: DataOpcode.stdout,
          channel: 2,
          payload: Uint8List.fromList([9, 9, 9]),
        ),
      );
      client.send(
        const ControlFrame(
          Hello(role: 'node', protocolVersion: 1, minVersion: 1, nonce: 'b'),
        ),
      );

      await _until(() => frames.length >= 3);
      await sub.cancel();

      expect(frames[0], isA<ControlFrame>());
      expect(((frames[0] as ControlFrame).message as Hello).nonce, 'a');
      expect(frames[1], isA<DataFrame>());
      expect((frames[1] as DataFrame).payload, orderedEquals([9, 9, 9]));
      expect(frames[2], isA<ControlFrame>());
      expect(((frames[2] as ControlFrame).message as Hello).nonce, 'b');
    },
  );

  test('a custom WebSocket close code propagates to the peer', () async {
    // omnyshell closes with app-specific codes (e.g. 4401 unauthorized). Verify
    // omnyhub's transport forwards them: the server side observes `done`.
    final serverDone = accepted.done;
    await client.close(4401, 'unauthorized');
    await serverDone.timeout(const Duration(seconds: 5));
    expect(accepted.isOpen, isFalse);
  });
}

/// Polls [condition] until it holds, yielding to the event loop between checks.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
