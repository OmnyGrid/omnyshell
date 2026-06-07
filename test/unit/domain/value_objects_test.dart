import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

void main() {
  group('NodeId', () {
    test('accepts valid ids and trims', () {
      expect(NodeId('  web-01 ').value, 'web-01');
      expect(NodeId('ci_runner.42').value, 'ci_runner.42');
    });

    test('rejects empty and invalid characters', () {
      expect(() => NodeId(''), throwsA(isA<ProtocolException>()));
      expect(() => NodeId('bad id'), throwsA(isA<ProtocolException>()));
      expect(() => NodeId('a/b'), throwsA(isA<ProtocolException>()));
    });

    test('supports value equality', () {
      expect(NodeId('a'), NodeId('a'));
      expect(NodeId('a').hashCode, NodeId('a').hashCode);
      expect(NodeId('a'), isNot(NodeId('b')));
    });
  });

  group('ChannelId', () {
    test('reserves 0 as the control channel', () {
      expect(ChannelId.control.isControl, isTrue);
      expect(ChannelId(5).isControl, isFalse);
    });

    test('rejects out-of-range values', () {
      expect(() => ChannelId(-1), throwsA(isA<ProtocolException>()));
      expect(() => ChannelId(0x1FFFFFFFF), throwsA(isA<ProtocolException>()));
    });
  });

  group('SessionId', () {
    test('generates unique ids', () {
      expect(SessionId.generate().value, isNot(SessionId.generate().value));
    });

    test('rejects empty', () {
      expect(() => SessionId(''), throwsA(isA<ProtocolException>()));
    });
  });

  group('Ed25519PublicKey', () {
    test('round-trips base64 and normalises padding', () {
      final key = Ed25519PublicKey.fromBytes(List<int>.filled(32, 7));
      final parsed = Ed25519PublicKey.fromBase64(key.base64);
      expect(parsed, key);
      expect(parsed.bytes.length, 32);
    });

    test('rejects wrong-length keys', () {
      expect(
        () => Ed25519PublicKey.fromBytes([1, 2, 3]),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('accepts url-safe base64', () {
      final key = Ed25519PublicKey.fromBytes(
        List<int>.generate(32, (i) => (i * 7) & 0xFF),
      );
      final urlSafe = key.base64.replaceAll('+', '-').replaceAll('/', '_');
      expect(Ed25519PublicKey.fromBase64(urlSafe), key);
    });
  });
}
