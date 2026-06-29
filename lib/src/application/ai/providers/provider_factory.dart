import 'package:http/http.dart' as http;

import '../ai_config.dart';
import 'ai_provider.dart';
import 'anthropic_provider.dart';
import 'gemini_provider.dart';
import 'openai_provider.dart';

/// Builds the [AiProvider] matching [config]'s provider kind, sharing [client]
/// for all requests.
AiProvider providerFor(AiConfig config, http.Client client) =>
    switch (config.provider) {
      AiProviderKind.anthropic => AnthropicProvider(config, client),
      AiProviderKind.openai => OpenAiProvider(config, client),
      AiProviderKind.gemini => GeminiProvider(config, client),
    };
