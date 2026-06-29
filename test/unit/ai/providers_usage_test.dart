import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnyshell/src/application/ai/ai_config.dart';
import 'package:omnyshell/src/application/ai/providers/ai_provider.dart';
import 'package:omnyshell/src/application/ai/providers/anthropic_provider.dart';
import 'package:omnyshell/src/application/ai/providers/gemini_provider.dart';
import 'package:omnyshell/src/application/ai/providers/openai_provider.dart';
import 'package:test/test.dart';

/// A [MockClient] that always replies with [body]/[status] and [headers].
http.Client _mock(
  String body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => MockClient(
  (_) async => http.Response(
    body,
    status,
    headers: {'content-type': 'application/json', ...headers},
  ),
);

const _msgs = [AiMessage.user('hi')];

void main() {
  group('AiUsage parsing', () {
    test(
      'Anthropic: input includes cache tokens; cached = cache_read',
      () async {
        final provider = AnthropicProvider(
          const AiConfig(
            provider: AiProviderKind.anthropic,
            model: 'm',
            apiKey: 'k',
          ),
          _mock(
            '{"content":[{"type":"text","text":"hello"}],'
            '"stop_reason":"end_turn",'
            '"usage":{"input_tokens":100,"output_tokens":20,'
            '"cache_read_input_tokens":30,"cache_creation_input_tokens":10}}',
          ),
        );

        final r = await provider.chat(messages: _msgs, tools: const []);
        expect(r.usage, isNotNull);
        expect(r.usage!.inputTokens, 140); // 100 + 30 (read) + 10 (creation)
        expect(r.usage!.outputTokens, 20);
        expect(r.usage!.cachedInputTokens, 30);
      },
    );

    test('OpenAI: prompt/completion tokens and cached subset', () async {
      final provider = OpenAiProvider(
        const AiConfig(
          provider: AiProviderKind.openai,
          model: 'm',
          apiKey: 'k',
        ),
        _mock(
          '{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}],'
          '"usage":{"prompt_tokens":200,"completion_tokens":40,'
          '"prompt_tokens_details":{"cached_tokens":50}}}',
        ),
      );

      final r = await provider.chat(messages: _msgs, tools: const []);
      expect(r.usage!.inputTokens, 200);
      expect(r.usage!.outputTokens, 40);
      expect(r.usage!.cachedInputTokens, 50);
    });

    test('Gemini: usageMetadata token counts', () async {
      final provider = GeminiProvider(
        const AiConfig(
          provider: AiProviderKind.gemini,
          model: 'm',
          apiKey: 'k',
        ),
        _mock(
          '{"candidates":[{"content":{"parts":[{"text":"hi"}]}}],'
          '"usageMetadata":{"promptTokenCount":300,"candidatesTokenCount":60,'
          '"cachedContentTokenCount":70}}',
        ),
      );

      final r = await provider.chat(messages: _msgs, tools: const []);
      expect(r.usage!.inputTokens, 300);
      expect(r.usage!.outputTokens, 60);
      expect(r.usage!.cachedInputTokens, 70);
    });

    test('missing usage object yields zero counts', () async {
      final provider = AnthropicProvider(
        const AiConfig(
          provider: AiProviderKind.anthropic,
          model: 'm',
          apiKey: 'k',
        ),
        _mock(
          '{"content":[{"type":"text","text":"hello"}],'
          '"stop_reason":"end_turn"}',
        ),
      );

      final r = await provider.chat(messages: _msgs, tools: const []);
      expect(r.usage!.inputTokens, 0);
      expect(r.usage!.outputTokens, 0);
      expect(r.usage!.cachedInputTokens, 0);
    });

    test(
      'Hub proxy elapsed-ms header overrides local request timing',
      () async {
        final provider = AnthropicProvider(
          const AiConfig(
            provider: AiProviderKind.anthropic,
            model: 'm',
            apiKey: 'k',
          ),
          _mock(
            '{"content":[{"type":"text","text":"hello"}],'
            '"stop_reason":"end_turn",'
            '"usage":{"input_tokens":5,"output_tokens":5}}',
            headers: {kAiProxyElapsedMsHeader: '4321'},
          ),
        );

        final r = await provider.chat(messages: _msgs, tools: const []);
        expect(r.usage!.requestMs, 4321);
      },
    );
  });

  group('helpers', () {
    test('aiTokenCount coerces and clamps', () {
      expect(aiTokenCount(null), 0);
      expect(aiTokenCount('nope'), 0);
      expect(aiTokenCount(12), 12);
      expect(aiTokenCount(12.9), 12);
      expect(aiTokenCount(-5), 0);
    });

    test('aiRequestMs prefers a valid header, else the local value', () {
      expect(aiRequestMs({kAiProxyElapsedMsHeader: '500'}, 999), 500);
      expect(aiRequestMs({kAiProxyElapsedMsHeader: 'x'}, 999), 999);
      expect(aiRequestMs({kAiProxyElapsedMsHeader: '-1'}, 999), 999);
      expect(aiRequestMs(const {}, 999), 999);
    });
  });
}
