@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:omnyshell/src/application/drive/drive_wire.dart';
import 'package:test/test.dart';

void main() {
  group('DriveMessage', () {
    test('round-trips a request header and payload', () {
      final payload = Uint8List.fromList([1, 2, 3, 250, 255]);
      final msg = DriveMessage.request(
        7,
        DriveOp.write,
        fields: {'path': 'a/b.txt'},
        payload: payload,
      );
      final decoded = DriveFrameReader().add(msg.encode());
      expect(decoded, hasLength(1));
      expect(decoded.single.id, 7);
      expect(decoded.single.op, DriveOp.write);
      expect(decoded.single.header['path'], 'a/b.txt');
      expect(decoded.single.payload, payload);
    });

    test('encodes ok/err responses', () {
      final ok = DriveMessage.ok(3, fields: {'head': 'abc'});
      expect(ok.ok, isTrue);
      expect(DriveFrameReader().add(ok.encode()).single.header['head'], 'abc');

      final err = DriveMessage.err(4, 'boom');
      final decoded = DriveFrameReader().add(err.encode()).single;
      expect(decoded.ok, isFalse);
      expect(decoded.error, 'boom');
    });
  });

  group('DriveFrameReader', () {
    test('reassembles multiple messages in one chunk', () {
      final a = DriveMessage.request(1, DriveOp.manifest).encode();
      final b = DriveMessage.request(
        2,
        DriveOp.read,
        fields: {'path': 'x'},
      ).encode();
      final buf = Uint8List.fromList([...a, ...b]);
      final msgs = DriveFrameReader().add(buf);
      expect(msgs.map((m) => m.id), [1, 2]);
      expect(msgs[1].header['path'], 'x');
    });

    test('reassembles a message split across byte boundaries', () {
      final payload = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final bytes = DriveMessage.ok(9, payload: payload).encode();
      final reader = DriveFrameReader();
      final out = <DriveMessage>[];
      // Feed one byte at a time — the reader must buffer partial frames.
      for (final b in bytes) {
        out.addAll(reader.add([b]));
      }
      expect(out, hasLength(1));
      expect(out.single.id, 9);
      expect(out.single.payload, payload);
    });

    test('handles a chunk carrying one whole and one partial frame', () {
      final first = DriveMessage.request(1, DriveOp.manifest).encode();
      final second = DriveMessage.request(2, DriveOp.gitHead).encode();
      final reader = DriveFrameReader();
      // First frame whole + first half of the second.
      final cut = second.length ~/ 2;
      var msgs = reader.add(
        Uint8List.fromList([...first, ...second.sublist(0, cut)]),
      );
      expect(msgs.map((m) => m.id), [1]);
      // Remainder completes the second frame.
      msgs = reader.add(second.sublist(cut));
      expect(msgs.map((m) => m.id), [2]);
    });
  });
}
