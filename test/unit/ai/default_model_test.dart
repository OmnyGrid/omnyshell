library;

import 'package:omnyshell/src/application/ai/ai_config.dart';
import 'package:test/test.dart';

void main() {
  group('defaultModelFor', () {
    test('returns the per-provider default model id', () {
      expect(defaultModelFor(AiProviderKind.anthropic), 'claude-haiku-4-5');
      expect(defaultModelFor(AiProviderKind.openai), 'gpt-4.1-mini');
      expect(defaultModelFor(AiProviderKind.gemini), 'gemini-2.5-flash');
    });
  });
}
