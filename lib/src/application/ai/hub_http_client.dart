import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../protocol/control_message.dart';
import '../client/client_runtime.dart';

/// An [http.Client] that tunnels requests through the Hub instead of issuing
/// them from the current process.
///
/// The browser client cannot call AI provider APIs directly (CORS), so it routes
/// each request through [ClientRuntime.proxyHttp]; the Hub performs the outbound
/// HTTPS request and returns the response. Because it satisfies the standard
/// `http.Client` contract, the existing Anthropic/OpenAI/Gemini providers use it
/// unchanged via `providerFor(config, HubHttpClient(...))`.
///
/// When [credentialMode] is [HttpProxyCredentialMode.hubDefault] the Hub injects
/// its own key for [provider] (the request need not carry one); otherwise the
/// request — including whatever `Authorization`/`x-api-key` header the provider
/// set from the client-supplied key — is forwarded verbatim.
class HubHttpClient extends http.BaseClient {
  /// The connected client runtime that brokers the request through the Hub.
  final ClientRuntime client;

  /// Whether the Hub should inject its default credentials.
  final HttpProxyCredentialMode credentialMode;

  /// The provider token, used by the Hub to pick the credential scheme when
  /// [credentialMode] is `hubDefault`.
  final String? provider;

  /// Creates a Hub-backed HTTP client.
  HubHttpClient(
    this.client, {
    this.credentialMode = HttpProxyCredentialMode.none,
    this.provider,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    final response = await client.proxyHttp(
      method: request.method,
      url: request.url.toString(),
      headers: Map<String, String>.from(request.headers),
      body: body,
      credentialMode: credentialMode,
      provider: provider,
    );
    if (response.error != null) {
      throw http.ClientException(response.error!, request.url);
    }
    final bytes = utf8.encode(response.body);
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: request,
      headers: response.headers,
    );
  }

  /// No-op: the shared [ClientRuntime]/Hub connection outlives this client and
  /// must not be torn down when a provider is disposed.
  @override
  void close() {}
}
