import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

void main() {
  late FrameCodec codec;

  setUp(() => codec = FrameCodec.standard());

  group('control frames', () {
    test('round-trips a connection-level message without a channel', () {
      final hello = Hello(
        role: 'hub',
        protocolVersion: 1,
        minVersion: 1,
        nonce: 'abc',
      );
      final encoded = codec.encodeControl(hello);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      expect(decoded['t'], 'hello');
      expect(decoded.containsKey('c'), isFalse);

      final frame = codec.decodeControl(encoded);
      expect(frame, isA<ControlFrame>());
      final message = frame.message;
      expect(message, isA<Hello>());
      expect((message as Hello).nonce, 'abc');
    });

    test('round-trips a channel-scoped message preserving the channel id', () {
      final open = SessionOpen(
        channel: 7,
        nodeId: 'web-01',
        mode: SessionMode.exec,
        command: 'uname -a',
      );
      final encoded = codec.encodeControl(open);
      expect(jsonDecode(encoded)['c'], 7);

      final decoded = codec.decodeControl(encoded).message as SessionOpen;
      expect(decoded.channel, 7);
      expect(decoded.nodeId, 'web-01');
      expect(decoded.command, 'uname -a');
      expect(decoded.mode, SessionMode.exec);
    });

    test('round-trips the optional exec shellFamily hint', () {
      // Present: carried on both client→Hub and Hub→node session-open frames.
      final open = SessionOpen(
        channel: 3,
        nodeId: 'win-01',
        mode: SessionMode.exec,
        command: 'compgen',
        shellFamily: ShellFamily.powershell,
      );
      expect(
        jsonDecode(codec.encodeControl(open))['d']['shellFamily'],
        'powershell',
      );
      final decodedOpen =
          codec.decodeControl(codec.encodeControl(open)).message as SessionOpen;
      expect(decodedOpen.shellFamily, ShellFamily.powershell);

      final nodeOpen = NodeSessionOpen(
        channel: 3,
        sessionId: 's1',
        principal: 'user:gmp',
        mode: SessionMode.exec,
        command: 'compgen',
        shellFamily: ShellFamily.cmd,
      );
      final decodedNode =
          codec.decodeControl(codec.encodeControl(nodeOpen)).message
              as NodeSessionOpen;
      expect(decodedNode.shellFamily, ShellFamily.cmd);

      // Absent: omitted from the wire and decodes back to null (back-compat).
      final plain = SessionOpen(
        channel: 1,
        nodeId: 'n',
        mode: SessionMode.exec,
      );
      expect(
        (jsonDecode(codec.encodeControl(plain))['d'] as Map).containsKey(
          'shellFamily',
        ),
        isFalse,
      );
      final decodedPlain =
          codec.decodeControl(codec.encodeControl(plain)).message
              as SessionOpen;
      expect(decodedPlain.shellFamily, isNull);
    });

    test('round-trips session-screen request/response messages', () {
      final req = SessionScreenRequest(
        requestId: 'r1',
        nodeId: 'web-01',
        sessionRef: 'ab12',
      );
      final decodedReq =
          codec.decodeControl(codec.encodeControl(req)).message
              as SessionScreenRequest;
      expect(decodedReq.requestId, 'r1');
      expect(decodedReq.nodeId, 'web-01');
      expect(decodedReq.sessionRef, 'ab12');

      final nodeReq = NodeSessionScreenRequest(
        requestId: 'r1',
        principal: 'user:gmp',
        sessionRef: 'ab12',
      );
      final decodedNodeReq =
          codec.decodeControl(codec.encodeControl(nodeReq)).message
              as NodeSessionScreenRequest;
      expect(decodedNodeReq.principal, 'user:gmp');
      expect(decodedNodeReq.sessionRef, 'ab12');

      final nodeResp = NodeSessionScreenResponse(
        requestId: 'r1',
        ok: true,
        screenBase64: base64.encode(utf8.encode('hi')),
        altScreen: true,
      );
      final decodedNodeResp =
          codec.decodeControl(codec.encodeControl(nodeResp)).message
              as NodeSessionScreenResponse;
      expect(decodedNodeResp.ok, isTrue);
      expect(utf8.decode(base64.decode(decodedNodeResp.screenBase64)), 'hi');
      expect(decodedNodeResp.altScreen, isTrue);

      final resp = SessionScreenResponse(
        requestId: 'r1',
        ok: false,
        message: 'No such session',
      );
      final decodedResp =
          codec.decodeControl(codec.encodeControl(resp)).message
              as SessionScreenResponse;
      expect(decodedResp.ok, isFalse);
      expect(decodedResp.message, 'No such session');
      expect(decodedResp.screenBase64, isEmpty);
      expect(decodedResp.altScreen, isFalse);
    });

    test('rejects an unknown message type', () {
      expect(
        () => codec.decodeControl('{"t":"nope","d":{}}'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects malformed JSON', () {
      expect(
        () => codec.decodeControl('not json'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('supports registering a custom control type', () {
      codec.register(
        'custom.thing',
        (channel, data) => Ping(
          id: data['id'] as String,
          ts: DateTime.parse(data['ts'] as String),
        ),
      );
      expect(codec.registeredTypes, contains('custom.thing'));
    });
  });

  group('data frames', () {
    test('encodes a 10-byte header followed by the payload', () {
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final bytes = codec.encodeData(
        DataFrame(
          opcode: DataOpcode.stdout,
          channel: 0x01020304,
          payload: payload,
        ),
      );
      expect(bytes.length, FrameCodec.headerSize + 4);
      expect(bytes[0], 1); // version
      expect(bytes[1], DataOpcode.stdout.wire);
      // channel id, big-endian.
      expect(bytes.sublist(2, 6), [0x01, 0x02, 0x03, 0x04]);
      // payload length, big-endian.
      expect(bytes.sublist(6, 10), [0, 0, 0, 4]);
      expect(bytes.sublist(10), [1, 2, 3, 4]);
    });

    test('round-trips a data frame', () {
      final original = DataFrame(
        opcode: DataOpcode.stderr,
        channel: 42,
        payload: Uint8List.fromList(utf8.encode('hello world')),
      );
      final decoded = codec.decodeData(codec.encodeData(original));
      expect(decoded.opcode, DataOpcode.stderr);
      expect(decoded.channel, 42);
      expect(utf8.decode(decoded.payload), 'hello world');
    });

    test('decode dispatches text to control and binary to data', () {
      final control = codec.encode(
        ControlFrame(Ping(id: 'p1', ts: DateTime.utc(2026))),
      );
      expect(control, isA<String>());
      expect(codec.decode(control), isA<ControlFrame>());

      final data = codec.encode(
        DataFrame(opcode: DataOpcode.stdin, channel: 1, payload: Uint8List(2)),
      );
      expect(data, isA<Uint8List>());
      expect(codec.decode(data), isA<DataFrame>());
    });

    test('rejects a truncated header', () {
      expect(
        () => codec.decodeData(Uint8List(4)),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a length/​payload mismatch', () {
      final bytes = codec.encodeData(
        DataFrame(
          opcode: DataOpcode.stdout,
          channel: 1,
          payload: Uint8List.fromList([1, 2, 3]),
        ),
      );
      // Corrupt the declared length.
      bytes[9] = 9;
      expect(() => codec.decodeData(bytes), throwsA(isA<ProtocolException>()));
    });

    test('rejects a payload over the maximum size', () {
      final tooBig = Uint8List(FrameCodec.maxDataPayload + 1);
      expect(
        () => codec.encodeData(
          DataFrame(opcode: DataOpcode.stdout, channel: 1, payload: tooBig),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
