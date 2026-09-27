@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

LocalCommandContext _ctx(List<String> out) => LocalCommandContext(
  node: NodeDescriptor(
    id: NodeId('n1'),
    displayName: 'n1',
    platform: const PlatformInfo(
      os: 'linux',
      arch: 'x64',
      agentVersion: '1.0.0',
      hostname: 'host',
    ),
    online: true,
  ),
  startedAt: DateTime.now(),
  writeLine: out.add,
);

/// The registered `:ai` command.
LocalCommand _ai(LocalCommandRegistry registry) =>
    registry.commands.singleWhere((c) => c.name == 'ai');

/// Whether the real environment configures an AI provider, which would make
/// the native loader find a key even without an `ai.yaml`.
bool get _envHasAiKey {
  final env = Platform.environment;
  return [
    'ANTHROPIC_API_KEY',
    'OPENAI_API_KEY',
    'GEMINI_API_KEY',
  ].any((k) => env[k]?.trim().isNotEmpty == true);
}

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('omny_ai_native'));
  tearDown(() => home.deleteSync(recursive: true));

  group('addAiCommand', () {
    test(
      'without a provider registers a setup stub that explains how',
      () async {
        final registry = LocalCommandRegistry()..addAiCommand(home: home.path);
        final ai = _ai(registry);
        expect(ai.description, contains('not configured'));

        final out = <String>[];
        await ai.run(_ctx(out), ['anything']);
        final text = out.join('\n');
        expect(text, contains('ai: no provider configured.'));
        expect(text, contains('ANTHROPIC_API_KEY'));
        expect(text, contains('~/.omnyshell/ai.yaml'));
        expect(text, contains('mode: plan'));
      },
      skip: _envHasAiKey ? 'an AI API key is set in the environment' : false,
    );

    group('with an ai.yaml', () {
      late LocalCommandRegistry registry;

      setUp(() {
        AiConfigIo.write(
          provider: AiProviderKind.anthropic,
          apiKey: 'sk-test',
          home: home.path,
        );
        registry = LocalCommandRegistry()
          ..addAiCommand(home: home.path, color: true);
      });
      tearDown(() => registry.dispose());

      AiConfig reload() =>
          AiConfigIo.load(home: home.path, environment: const {})!;

      test('registers the live agent command', () {
        expect(_ai(registry), isA<AiCommand>());
        expect(_ai(registry).description, contains('AI agent'));
      });

      test('persists a mode change to ai.yaml', () async {
        final out = <String>[];
        await _ai(registry).run(_ctx(out), ['mode', 'auto']);
        expect(out, ['ai: mode set to auto']);
        expect(reload().defaultMode, AgentMode.auto);
      });

      test('persists a language, and `off` clears it', () async {
        await _ai(registry).run(_ctx([]), ['lang', 'spanish']);
        expect(reload().language, 'spanish');

        await _ai(registry).run(_ctx([]), ['lang', 'off']);
        expect(reload().language, isNull);
        expect(reload().apiKey, 'sk-test'); // other keys kept
      });
    });
  });
}
