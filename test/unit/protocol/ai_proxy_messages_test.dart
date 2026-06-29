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

  group('AI config messages', () {
    test('AiConfigRequest round-trips', () {
      final out = roundTrip(const AiConfigRequest(requestId: 'r1'));
      expect(out.requestId, 'r1');
    });

    test('AiConfigResponse round-trips all fields (no key)', () {
      final out = roundTrip(
        const AiConfigResponse(
          requestId: 'r2',
          available: true,
          provider: 'anthropic',
          model: 'claude-haiku-4-5',
          plannerModel: 'claude-sonnet-4-6',
          executorModel: 'claude-haiku-4-5',
          explainerModel: 'claude-haiku-4-5',
          baseUrl: 'https://example.test',
          mode: 'plan',
          language: 'portuguese',
        ),
      );
      expect(out.available, isTrue);
      expect(out.provider, 'anthropic');
      expect(out.model, 'claude-haiku-4-5');
      expect(out.plannerModel, 'claude-sonnet-4-6');
      expect(out.baseUrl, 'https://example.test');
      expect(out.mode, 'plan');
      expect(out.language, 'portuguese');
    });

    test('AiConfigResponse round-trips the unavailable case', () {
      final out = roundTrip(
        const AiConfigResponse(requestId: 'r3', available: false),
      );
      expect(out.available, isFalse);
      expect(out.provider, isNull);
      expect(out.model, isNull);
    });
  });

  group('HTTP proxy messages', () {
    test('HttpProxyRequest round-trips with credentials + headers', () {
      final out = roundTrip(
        const HttpProxyRequest(
          requestId: 'q1',
          method: 'POST',
          url: 'https://api.anthropic.com/v1/messages',
          headers: {'content-type': 'application/json'},
          body: '{"model":"m"}',
          credentialMode: HttpProxyCredentialMode.hubDefault,
          provider: 'anthropic',
        ),
      );
      expect(out.method, 'POST');
      expect(out.url, 'https://api.anthropic.com/v1/messages');
      expect(out.headers['content-type'], 'application/json');
      expect(out.body, '{"model":"m"}');
      expect(out.credentialMode, HttpProxyCredentialMode.hubDefault);
      expect(out.provider, 'anthropic');
    });

    test('HttpProxyRequest defaults credentialMode to none', () {
      final out = roundTrip(
        const HttpProxyRequest(
          requestId: 'q2',
          method: 'POST',
          url: 'https://api.openai.com/v1/chat/completions',
          headers: {},
          body: '{}',
        ),
      );
      expect(out.credentialMode, HttpProxyCredentialMode.none);
      expect(out.provider, isNull);
    });

    test('HttpProxyResponse round-trips a success', () {
      final out = roundTrip(
        const HttpProxyResponse(
          requestId: 'q1',
          statusCode: 200,
          headers: {'content-type': 'application/json'},
          body: '{"ok":true}',
        ),
      );
      expect(out.statusCode, 200);
      expect(out.headers['content-type'], 'application/json');
      expect(out.body, '{"ok":true}');
      expect(out.error, isNull);
    });

    test('HttpProxyResponse round-trips an error', () {
      final out = roundTrip(
        const HttpProxyResponse(
          requestId: 'q1',
          statusCode: 0,
          error: 'host not allowed: evil.test',
        ),
      );
      expect(out.statusCode, 0);
      expect(out.error, 'host not allowed: evil.test');
    });
  });

  test('HttpProxyCredentialMode.fromWire defaults to none for unknown', () {
    expect(
      HttpProxyCredentialMode.fromWire('hubDefault'),
      HttpProxyCredentialMode.hubDefault,
    );
    expect(
      HttpProxyCredentialMode.fromWire('none'),
      HttpProxyCredentialMode.none,
    );
    expect(
      HttpProxyCredentialMode.fromWire('bogus'),
      HttpProxyCredentialMode.none,
    );
    expect(
      HttpProxyCredentialMode.fromWire(null),
      HttpProxyCredentialMode.none,
    );
  });
}
