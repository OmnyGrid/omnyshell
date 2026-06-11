import 'package:omnyshell/src/protocol/control_message.dart';
import 'package:test/test.dart';

void main() {
  group('SessionOpened shell family field', () {
    test('round-trips a non-posix family', () {
      const msg = SessionOpened(
        channel: 3,
        sessionId: 's1',
        pty: true,
        shell: 'powershell',
      );
      final decoded = SessionOpened.fromJson(3, msg.toJson());
      expect(decoded.shell, 'powershell');
    });

    test('omits the field for posix and defaults on decode', () {
      const msg = SessionOpened(channel: 1, sessionId: 's2');
      expect(msg.toJson().containsKey('shell'), isFalse);
      // An older hub that never sends the field decodes as posix.
      final decoded = SessionOpened.fromJson(1, {'sessionId': 's2'});
      expect(decoded.shell, 'posix');
    });
  });

  group('NodeSessionOpened shell family field', () {
    test('round-trips a non-posix family', () {
      const msg = NodeSessionOpened(channel: 7, sessionId: 'n1', shell: 'cmd');
      final decoded = NodeSessionOpened.fromJson(7, msg.toJson());
      expect(decoded.shell, 'cmd');
    });

    test('defaults to posix when absent', () {
      final decoded = NodeSessionOpened.fromJson(7, {'sessionId': 'n2'});
      expect(decoded.shell, 'posix');
    });
  });
}
