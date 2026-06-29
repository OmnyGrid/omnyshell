import 'package:http/http.dart' as http;

import '../../protocol/control_message.dart';
import '../ai/ai_config.dart';
import '../ai/providers/ai_provider.dart' show kAiProxyElapsedMsHeader;

/// Proxies authenticated clients' outbound HTTPS requests to AI provider APIs.
///
/// A browser client cannot call `api.anthropic.com` and friends directly (CORS,
/// and it should not hold the operator's keys), so the Hub makes the request on
/// its behalf. The proxy is deliberately narrow:
///
/// * **Authenticated callers only** — the broker dispatches [handle] solely for
///   authenticated client peers; the proxy is never reachable pre-auth.
/// * **Allowlisted hosts + https only** — requests to anything other than the
///   known AI provider hosts (plus an optional configured [defaultConfig]
///   `baseUrl` host) are rejected. This is the SSRF boundary; do not widen it
///   into a general fetch.
/// * **Optional credential injection** — with [HttpProxyCredentialMode.hubDefault]
///   the Hub injects its configured key for the matched provider, so the key
///   never leaves the Hub. With [HttpProxyCredentialMode.none] the client's own
///   request (key included) is forwarded verbatim.
class HttpProxyService {
  /// The Hub's default AI configuration, used for `hubDefault` credential
  /// injection and config discovery. `null` when the Hub has no AI key
  /// configured (only the bring-your-own-key path then works).
  final AiConfig? defaultConfig;

  /// The HTTP client used for outbound requests (injectable for tests).
  final http.Client httpClient;

  /// How long to wait for a provider response before failing.
  final Duration timeout;

  /// The fixed set of AI provider hosts the proxy may reach.
  static const Set<String> _providerHosts = {
    'api.anthropic.com',
    'api.openai.com',
    'generativelanguage.googleapis.com',
  };

  /// Creates an HTTP proxy service.
  HttpProxyService({
    this.defaultConfig,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 120),
  }) : httpClient = httpClient ?? http.Client();

  /// The hosts this proxy will reach: the fixed provider hosts plus the host of
  /// any configured [defaultConfig] `baseUrl` override.
  Set<String> get _allowedHosts {
    final base = defaultConfig?.baseUrl;
    if (base == null || base.isEmpty) return _providerHosts;
    final host = Uri.tryParse(base)?.host;
    if (host == null || host.isEmpty) return _providerHosts;
    return {..._providerHosts, host};
  }

  /// Builds the config-discovery reply, omitting the API key.
  AiConfigResponse describe(String requestId) {
    final config = defaultConfig;
    if (config == null) {
      return AiConfigResponse(requestId: requestId, available: false);
    }
    return AiConfigResponse(
      requestId: requestId,
      available: true,
      provider: config.provider.wireName,
      model: config.model,
      plannerModel: config.plannerModel,
      executorModel: config.executorModel,
      explainerModel: config.explainerModel,
      baseUrl: config.baseUrl,
      mode: config.defaultMode.wireName,
      language: config.language,
    );
  }

  /// Performs [req] and returns the proxied response, or an error response on a
  /// rejected target / transport failure.
  Future<HttpProxyResponse> handle(HttpProxyRequest req) async {
    final uri = Uri.tryParse(req.url);
    if (uri == null || !uri.hasScheme) {
      return _error(req, 'invalid url');
    }
    if (uri.scheme != 'https') {
      return _error(req, 'only https is allowed');
    }
    if (!_allowedHosts.contains(uri.host)) {
      return _error(req, 'host not allowed: ${uri.host}');
    }

    final headers = <String, String>{...req.headers};
    final Uri target;
    try {
      target = _applyCredentials(req, uri, headers);
    } on _CredentialError catch (e) {
      return _error(req, e.message);
    }

    final stopwatch = Stopwatch()..start();
    try {
      final request = http.Request(req.method, target)
        ..headers.addAll(headers)
        ..body = req.body;
      final streamed = await httpClient.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed);
      stopwatch.stop();
      // Report the real upstream duration so a proxied client measures the
      // model's generation speed without the browser↔Hub round-trip (see
      // [aiRequestMs]).
      return HttpProxyResponse(
        requestId: req.requestId,
        statusCode: response.statusCode,
        headers: {
          ...response.headers,
          kAiProxyElapsedMsHeader: '${stopwatch.elapsedMilliseconds}',
        },
        body: response.body,
      );
    } on Object catch (e) {
      return _error(req, 'request failed: $e');
    }
  }

  /// Injects the Hub's default credentials when [req] asks for them, returning
  /// the (possibly rewritten) target URL. For `none` mode the request is left
  /// untouched. Throws [_CredentialError] when the Hub cannot supply a key for
  /// the requested provider.
  Uri _applyCredentials(
    HttpProxyRequest req,
    Uri uri,
    Map<String, String> headers,
  ) {
    if (req.credentialMode == HttpProxyCredentialMode.none) return uri;

    final config = defaultConfig;
    if (config == null) {
      throw const _CredentialError('hub has no AI provider configured');
    }
    final provider = AiProviderKind.tryParse(req.provider) ?? config.provider;
    if (provider != config.provider) {
      throw _CredentialError(
        'hub has no key for provider ${provider.wireName}',
      );
    }
    final key = config.apiKey;
    switch (provider) {
      case AiProviderKind.anthropic:
        headers['x-api-key'] = key;
        return uri;
      case AiProviderKind.openai:
        headers['authorization'] = 'Bearer $key';
        return uri;
      case AiProviderKind.gemini:
        return uri.replace(
          queryParameters: {...uri.queryParameters, 'key': key},
        );
    }
  }

  HttpProxyResponse _error(HttpProxyRequest req, String message) =>
      HttpProxyResponse(
        requestId: req.requestId,
        statusCode: 0,
        error: message,
      );

  /// Releases the HTTP client.
  void close() => httpClient.close();
}

class _CredentialError implements Exception {
  const _CredentialError(this.message);
  final String message;
}
