import 'package:http/http.dart' as http;
import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/src/application/ai/hub_http_client.dart';
import 'package:test/test.dart';

/// One `proxyHttp` call as the [HubHttpClient] made it.
typedef _ProxyCall = ({
  String method,
  String url,
  Map<String, String> headers,
  String body,
  HttpProxyCredentialMode credentialMode,
  String? provider,
});

/// A [ClientRuntime] whose `proxyHttp` answers with [reply] instead of going
/// through a Hub, recording each request.
class _ProxyRuntime extends ClientRuntime {
  _ProxyRuntime(this.reply)
    : super(
        ClientConfig(
          hubUri: Uri.parse('wss://localhost:1/'),
          credentials: const TokenCredentialProvider(
            principal: 'tester',
            token: 'tok',
          ),
        ),
      );

  final HttpProxyResponse reply;
  final List<_ProxyCall> calls = [];

  @override
  Future<HttpProxyResponse> proxyHttp({
    required String method,
    required String url,
    Map<String, String> headers = const {},
    String body = '',
    HttpProxyCredentialMode credentialMode = HttpProxyCredentialMode.none,
    String? provider,
  }) async {
    calls.add((
      method: method,
      url: url,
      headers: headers,
      body: body,
      credentialMode: credentialMode,
      provider: provider,
    ));
    return reply;
  }
}

void main() {
  final url = Uri.parse('https://api.example.com/v1/messages');

  group('HubHttpClient', () {
    test('forwards the request through the Hub and maps the reply', () async {
      final runtime = _ProxyRuntime(
        const HttpProxyResponse(
          requestId: 'r1',
          statusCode: 201,
          headers: {'content-type': 'application/json'},
          body: '{"ok":"çé"}',
        ),
      );
      final client = HubHttpClient(runtime);

      final response = await client.post(
        url,
        headers: {'x-api-key': 'sk-client'},
        body: '{"q":1}',
      );

      final call = runtime.calls.single;
      expect(call.method, 'POST');
      expect(call.url, url.toString());
      expect(call.headers['x-api-key'], 'sk-client');
      expect(call.body, '{"q":1}');
      expect(call.credentialMode, HttpProxyCredentialMode.none);
      expect(call.provider, isNull);

      expect(response.statusCode, 201);
      expect(response.headers['content-type'], 'application/json');
      expect(response.body, '{"ok":"çé"}'); // UTF-8 survives the round trip
      expect(response.request?.url, url);
    });

    test('asks the Hub to inject its own key in hubDefault mode', () async {
      final runtime = _ProxyRuntime(
        const HttpProxyResponse(requestId: 'r1', statusCode: 200),
      );
      final client = HubHttpClient(
        runtime,
        credentialMode: HttpProxyCredentialMode.hubDefault,
        provider: 'anthropic',
      );

      final response = await client.get(url);

      expect(runtime.calls.single.method, 'GET');
      expect(runtime.calls.single.body, isEmpty);
      expect(
        runtime.calls.single.credentialMode,
        HttpProxyCredentialMode.hubDefault,
      );
      expect(runtime.calls.single.provider, 'anthropic');
      expect(response.body, isEmpty);
    });

    test('a Hub-side error surfaces as a ClientException', () async {
      final client = HubHttpClient(
        _ProxyRuntime(
          const HttpProxyResponse(
            requestId: 'r1',
            statusCode: 0,
            error: 'upstream unreachable',
          ),
        ),
      );

      await expectLater(
        client.get(url),
        throwsA(
          isA<http.ClientException>()
              .having((e) => e.message, 'message', 'upstream unreachable')
              .having((e) => e.uri, 'uri', url),
        ),
      );
    });

    test('close leaves the shared Hub connection usable', () async {
      final runtime = _ProxyRuntime(
        const HttpProxyResponse(requestId: 'r1', statusCode: 200, body: 'x'),
      );
      final client = HubHttpClient(runtime)..close();

      // A provider disposing its client must not break later requests.
      expect((await client.get(url)).body, 'x');
      expect(runtime.calls, hasLength(1));
    });
  });
}
