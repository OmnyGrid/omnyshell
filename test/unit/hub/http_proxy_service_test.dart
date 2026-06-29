import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:test/test.dart';

void main() {
  const anthropicUrl = 'https://api.anthropic.com/v1/messages';

  HttpProxyService service({
    AiConfig? config,
    required Future<http.Response> Function(http.Request request) handler,
  }) => HttpProxyService(
    defaultConfig: config,
    httpClient: MockClient((req) => handler(req)),
  );

  HttpProxyRequest request({
    String url = anthropicUrl,
    HttpProxyCredentialMode mode = HttpProxyCredentialMode.none,
    String? provider,
    Map<String, String> headers = const {'content-type': 'application/json'},
  }) => HttpProxyRequest(
    requestId: 'r1',
    method: 'POST',
    url: url,
    headers: headers,
    body: '{"model":"m"}',
    credentialMode: mode,
    provider: provider,
  );

  group('allowlist + scheme', () {
    test('rejects a non-allowlisted host', () async {
      final svc = service(handler: (_) async => fail('should not dispatch'));
      final res = await svc.handle(request(url: 'https://evil.test/v1'));
      expect(res.statusCode, 0);
      expect(res.error, contains('host not allowed'));
    });

    test('rejects a non-https scheme', () async {
      final svc = service(handler: (_) async => fail('should not dispatch'));
      final res = await svc.handle(
        request(url: 'http://api.anthropic.com/v1/messages'),
      );
      expect(res.statusCode, 0);
      expect(res.error, contains('https'));
    });

    test('allows a configured baseUrl host', () async {
      final svc = service(
        config: const AiConfig(
          provider: AiProviderKind.openai,
          model: 'm',
          apiKey: 'k',
          baseUrl: 'https://proxy.internal.test',
        ),
        handler: (req) async {
          expect(req.url.host, 'proxy.internal.test');
          return http.Response('{"ok":true}', 200);
        },
      );
      final res = await svc.handle(
        request(url: 'https://proxy.internal.test/v1/chat/completions'),
      );
      expect(res.statusCode, 200);
    });
  });

  group('credential injection (hubDefault)', () {
    test('injects the Anthropic x-api-key header', () async {
      late http.Request seen;
      final svc = service(
        config: const AiConfig(
          provider: AiProviderKind.anthropic,
          model: 'm',
          apiKey: 'sk-ant',
        ),
        handler: (req) async {
          seen = req;
          return http.Response('{"ok":true}', 200);
        },
      );
      final res = await svc.handle(
        request(mode: HttpProxyCredentialMode.hubDefault),
      );
      expect(seen.headers['x-api-key'], 'sk-ant');
      expect(res.statusCode, 200);
      expect(res.body, '{"ok":true}');
    });

    test('injects the OpenAI bearer token', () async {
      late http.Request seen;
      final svc = service(
        config: const AiConfig(
          provider: AiProviderKind.openai,
          model: 'm',
          apiKey: 'sk-oai',
        ),
        handler: (req) async {
          seen = req;
          return http.Response('{}', 200);
        },
      );
      await svc.handle(
        request(
          url: 'https://api.openai.com/v1/chat/completions',
          mode: HttpProxyCredentialMode.hubDefault,
          provider: 'openai',
        ),
      );
      expect(seen.headers['authorization'], 'Bearer sk-oai');
    });

    test('injects the Gemini key query param', () async {
      late http.Request seen;
      final svc = service(
        config: const AiConfig(
          provider: AiProviderKind.gemini,
          model: 'm',
          apiKey: 'g-key',
        ),
        handler: (req) async {
          seen = req;
          return http.Response('{}', 200);
        },
      );
      await svc.handle(
        request(
          url:
              'https://generativelanguage.googleapis.com/v1beta/models/m:generateContent',
          mode: HttpProxyCredentialMode.hubDefault,
          provider: 'gemini',
        ),
      );
      expect(seen.url.queryParameters['key'], 'g-key');
    });

    test('errors when the hub has no provider configured', () async {
      final svc = service(handler: (_) async => fail('should not dispatch'));
      final res = await svc.handle(
        request(mode: HttpProxyCredentialMode.hubDefault),
      );
      expect(res.statusCode, 0);
      expect(res.error, contains('no AI provider'));
    });

    test('errors when asked for a provider the hub lacks a key for', () async {
      final svc = service(
        config: const AiConfig(
          provider: AiProviderKind.anthropic,
          model: 'm',
          apiKey: 'sk',
        ),
        handler: (_) async => fail('should not dispatch'),
      );
      final res = await svc.handle(
        request(
          url: 'https://api.openai.com/v1/chat/completions',
          mode: HttpProxyCredentialMode.hubDefault,
          provider: 'openai',
        ),
      );
      expect(res.statusCode, 0);
      expect(res.error, contains('no key for provider openai'));
    });
  });

  group('credential mode none (bring-your-own-key)', () {
    test('forwards the request verbatim without injecting', () async {
      late http.Request seen;
      final svc = service(
        handler: (req) async {
          seen = req;
          return http.Response('{}', 200);
        },
      );
      await svc.handle(request(headers: {'x-api-key': 'user-key'}));
      expect(seen.headers['x-api-key'], 'user-key');
    });

    test('surfaces a transport failure as an error response', () async {
      final svc = service(
        handler: (_) async => throw http.ClientException('boom'),
      );
      final res = await svc.handle(request());
      expect(res.statusCode, 0);
      expect(res.error, contains('request failed'));
    });
  });

  group('describe', () {
    test('reports unavailable without a default config', () {
      final svc = service(handler: (_) async => http.Response('', 200));
      final out = svc.describe('rq');
      expect(out.available, isFalse);
      expect(out.provider, isNull);
    });

    test('reports the default provider/model but never the key', () {
      final svc = service(
        config: const AiConfig(
          provider: AiProviderKind.anthropic,
          model: 'claude-haiku-4-5',
          apiKey: 'secret',
          plannerModel: 'claude-sonnet-4-6',
        ),
        handler: (_) async => http.Response('', 200),
      );
      final out = svc.describe('rq');
      expect(out.available, isTrue);
      expect(out.provider, 'anthropic');
      expect(out.model, 'claude-haiku-4-5');
      expect(out.plannerModel, 'claude-sonnet-4-6');
      expect(out.toJson().toString(), isNot(contains('secret')));
    });
  });
}
