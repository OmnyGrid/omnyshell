import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyhub/omnyhub.dart' as omnyhub;
import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/src/infrastructure/transport/frame_connection.dart';
import 'package:test/test.dart';

/// An in-memory omnyhub [omnyhub.Connection] the test drives directly: whatever
/// is [send]-ed is captured in [sent], and [deliver] pushes an inbound
/// [omnyhub.Message] as if it arrived from the peer.
class _FakeConnection implements omnyhub.Connection {
  final _incoming = StreamController<omnyhub.Message>();
  final _done = Completer<void>();
  final List<omnyhub.Message> sent = [];
  bool _open = true;

  void deliver(omnyhub.Message message) => _incoming.add(message);

  @override
  Stream<omnyhub.Message> get incoming => _incoming.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> get done => _done.future;

  @override
  String? get remoteAddress => '203.0.113.9';

  @override
  void send(omnyhub.Message message) => sent.add(message);

  @override
  Future<void> close([int? code, String? reason]) async {
    _open = false;
    // Don't await: closing a single-subscription controller that was never
    // listened returns a future that only completes once drained.
    unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }
}

void main() {
  group('FrameConnection', () {
    late _FakeConnection raw;
    late FrameConnection conn;

    setUp(() {
      raw = _FakeConnection();
      conn = FrameConnection.wrap(raw);
    });

    test('encodes a control frame as an omnyhub text message', () {
      conn.send(
        const ControlFrame(
          Hello(role: 'hub', protocolVersion: 1, minVersion: 1, nonce: 'abc'),
        ),
      );

      expect(raw.sent, hasLength(1));
      final message = raw.sent.single;
      expect(message, isA<omnyhub.TextMessage>());
      expect(jsonDecode((message as omnyhub.TextMessage).data)['t'], 'hello');
    });

    test('encodes a data frame as an omnyhub binary message', () {
      conn.send(
        DataFrame(
          opcode: DataOpcode.stdout,
          channel: 3,
          payload: Uint8List.fromList([1, 2, 3]),
        ),
      );

      expect(raw.sent.single, isA<omnyhub.BinaryMessage>());
    });

    test('decodes an inbound text message into a ControlFrame', () async {
      final frames = <OmnyShellFrame>[];
      conn.incoming.listen(frames.add);

      final encoded = FrameCodec.standard().encodeControl(
        const Hello(
          role: 'node',
          protocolVersion: 1,
          minVersion: 1,
          nonce: 'z',
        ),
      );
      raw.deliver(omnyhub.TextMessage(encoded));
      await pumpEventQueue();

      expect(frames, hasLength(1));
      final frame = frames.single as ControlFrame;
      expect((frame.message as Hello).nonce, 'z');
    });

    test('round-trips a data frame through encode + decode', () async {
      final frames = <OmnyShellFrame>[];
      conn.incoming.listen(frames.add);

      final codec = FrameCodec.standard();
      final encoded = codec.encode(
        DataFrame(
          opcode: DataOpcode.stderr,
          channel: 9,
          payload: Uint8List.fromList([9, 8, 7]),
        ),
      );
      raw.deliver(omnyhub.BinaryMessage(encoded as List<int>));
      await pumpEventQueue();

      final frame = frames.single as DataFrame;
      expect(frame.opcode, DataOpcode.stderr);
      expect(frame.channel, 9);
      expect(frame.payload, [9, 8, 7]);
    });

    test('drops an undecodable inbound frame without tearing down', () async {
      final frames = <OmnyShellFrame>[];
      final errors = <Object>[];
      conn.incoming.listen(frames.add, onError: errors.add);

      raw.deliver(const omnyhub.TextMessage('not valid json {{{'));
      // A valid frame after the bad one still arrives.
      raw.deliver(
        omnyhub.TextMessage(
          FrameCodec.standard().encodeControl(
            const Hello(
              role: 'node',
              protocolVersion: 1,
              minVersion: 1,
              nonce: 'after-bad',
            ),
          ),
        ),
      );
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect(frames, hasLength(1));
      expect((frames.single as ControlFrame).message, isA<Hello>());
      expect(
        ((frames.single as ControlFrame).message as Hello).nonce,
        'after-bad',
      );
    });

    test('close() closes the underlying connection', () async {
      expect(conn.isOpen, isTrue);
      await conn.close();
      expect(raw.isOpen, isFalse);
      await conn.done;
    });
  });
}
