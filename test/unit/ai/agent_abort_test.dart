import 'package:omnyshell/src/application/ai/agent_abort.dart';
import 'package:test/test.dart';

void main() {
  group('AgentAbort', () {
    test('request is unconfirmed; requestConfirmed marks it confirmed', () {
      final a = AgentAbort();
      expect(a.isRequested, isFalse);
      a.request();
      expect(a.isRequested, isTrue);
      expect(a.isConfirmed, isFalse);
      a.confirm();
      expect(a.isConfirmed, isTrue);

      final b = AgentAbort()..requestConfirmed();
      expect(b.isRequested, isTrue);
      expect(b.isConfirmed, isTrue);
    });

    test('whenRequested completes on request', () async {
      final a = AgentAbort();
      var fired = false;
      final f = a.whenRequested.then((_) => fired = true);
      expect(fired, isFalse);
      a.request();
      await f;
      expect(fired, isTrue);
    });

    test('clear re-arms whenRequested for a later request', () async {
      final a = AgentAbort()..request();
      a.clear();
      expect(a.isRequested, isFalse);
      var fired = false;
      final f = a.whenRequested.then((_) => fired = true);
      a.request();
      await f;
      expect(fired, isTrue);
    });
  });
}
