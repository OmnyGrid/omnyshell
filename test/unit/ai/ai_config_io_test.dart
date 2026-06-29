import 'dart:io';

import 'package:omnyshell/src/application/ai/agent_mode.dart';
import 'package:omnyshell/src/application/ai/ai_config.dart';
import 'package:omnyshell/src/application/ai/ai_config_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('omny_ai_cfg'));
  tearDown(() => home.deleteSync(recursive: true));

  // Avoid leaking real env keys into resolution: pass an empty environment.
  const noEnv = <String, String>{};

  group('write + load round-trip', () {
    test('persists all fields and reads them back', () {
      AiConfigIo.write(
        provider: AiProviderKind.openai,
        model: 'gpt-test',
        plannerModel: 'gpt-strong',
        executorModel: 'gpt-cheap',
        apiKey: 'sk-secret-1234',
        mode: AgentMode.auto,
        language: 'portuguese',
        baseUrl: 'https://proxy.example/v1',
        maxSteps: 7,
        home: home.path,
      );

      final cfg = AiConfigIo.load(home: home.path, environment: noEnv)!;
      expect(cfg.provider, AiProviderKind.openai);
      expect(cfg.model, 'gpt-test');
      expect(cfg.plannerModel, 'gpt-strong');
      expect(cfg.executorModel, 'gpt-cheap');
      expect(cfg.apiKey, 'sk-secret-1234');
      expect(cfg.defaultMode, AgentMode.auto);
      expect(cfg.language, 'portuguese');
      expect(cfg.baseUrl, 'https://proxy.example/v1');
      expect(cfg.maxSteps, 7);
    });

    test('applies the per-provider default model and planner when unset', () {
      // Only an API key in the env, no ai.yaml: provider is inferred and the
      // model/planner come from the per-provider defaults.
      final cfg = AiConfigIo.load(
        home: home.path,
        environment: const {'OPENAI_API_KEY': 'sk-x'},
      )!;
      expect(cfg.provider, AiProviderKind.openai);
      expect(cfg.model, 'gpt-4.1-mini');
      expect(cfg.plannerModel, 'gpt-5.4-mini');
      expect(cfg.executorModel, isNull); // executor uses model
      expect(cfg.modelFor(AgentPhase.planning), 'gpt-5.4-mini');
      expect(cfg.modelFor(AgentPhase.executing), 'gpt-4.1-mini');
    });

    test('an explicit ai.yaml planner overrides the default', () {
      AiConfigIo.write(
        provider: AiProviderKind.openai,
        apiKey: 'k',
        plannerModel: 'gpt-custom',
        home: home.path,
      );
      final cfg = AiConfigIo.load(home: home.path, environment: noEnv)!;
      expect(cfg.plannerModel, 'gpt-custom');
    });

    test('clearing the language (empty) reads back as null', () {
      AiConfigIo.write(
        provider: AiProviderKind.anthropic,
        apiKey: 'k',
        language: 'spanish',
        home: home.path,
      );
      AiConfigIo.write(language: '', home: home.path); // clear
      final cfg = AiConfigIo.load(home: home.path, environment: noEnv)!;
      expect(cfg.language, isNull);
    });

    test('modelFor falls back to model, or uses per-phase overrides', () {
      const shared = AiConfig(
        provider: AiProviderKind.anthropic,
        model: 'm',
        apiKey: 'k',
      );
      expect(shared.modelFor(AgentPhase.planning), 'm');
      expect(shared.modelFor(AgentPhase.executing), 'm');

      const split = AiConfig(
        provider: AiProviderKind.anthropic,
        model: 'm',
        apiKey: 'k',
        plannerModel: 'p',
        executorModel: 'e',
      );
      expect(split.modelFor(AgentPhase.planning), 'p');
      expect(split.modelFor(AgentPhase.executing), 'e');
    });

    test(
      'explainModel falls back to model (not planner), or uses explainerModel',
      () {
        const withPlanner = AiConfig(
          provider: AiProviderKind.anthropic,
          model: 'm',
          apiKey: 'k',
          plannerModel: 'p',
        );
        expect(
          withPlanner.explainModel,
          'm',
        ); // falls back to model, not planner

        const withExplainer = AiConfig(
          provider: AiProviderKind.anthropic,
          model: 'm',
          apiKey: 'k',
          plannerModel: 'p',
          explainerModel: 'x',
        );
        expect(withExplainer.explainModel, 'x');
      },
    );

    test('an empty-string value clears the key back to the default', () {
      AiConfigIo.write(
        provider: AiProviderKind.anthropic,
        apiKey: 'k',
        model: 'custom-model',
        plannerModel: 'custom-planner',
        executorModel: 'custom-exec',
        home: home.path,
      );
      // Clear the model overrides (planner/executor) and the shared model.
      AiConfigIo.write(
        model: '',
        plannerModel: '',
        executorModel: '',
        home: home.path,
      );

      final raw = File(
        AiConfigIo.defaultPath(home: home.path),
      ).readAsStringSync();
      expect(raw.contains('custom-model'), isFalse);
      expect(raw.contains('custom-planner'), isFalse);
      expect(raw.contains('custom-exec'), isFalse);
      // The key and provider survive the clear.
      expect(raw.contains('apiKey'), isTrue);

      // Resolution falls back to the per-provider defaults.
      final cfg = AiConfigIo.load(home: home.path, environment: noEnv)!;
      expect(cfg.model, 'claude-haiku-4-5');
      expect(cfg.plannerModel, 'claude-sonnet-4-6'); // default planner
      expect(cfg.executorModel, isNull); // executor uses model
    });

    test('clearing a never-set key is a no-op (no crash)', () {
      AiConfigIo.write(
        provider: AiProviderKind.anthropic,
        apiKey: 'k',
        home: home.path,
      );
      // executorModel was never written; clearing it must not throw.
      AiConfigIo.write(executorModel: '', home: home.path);
      final cfg = AiConfigIo.load(home: home.path, environment: noEnv)!;
      expect(cfg.executorModel, isNull);
      expect(cfg.apiKey, 'k');
    });

    test('partial write preserves previously written fields', () {
      AiConfigIo.write(
        provider: AiProviderKind.anthropic,
        apiKey: 'sk-keep-9999',
        home: home.path,
      );
      // Update only the model; the key must survive.
      AiConfigIo.write(model: 'claude-test', home: home.path);

      final cfg = AiConfigIo.load(home: home.path, environment: noEnv)!;
      expect(cfg.provider, AiProviderKind.anthropic);
      expect(cfg.model, 'claude-test');
      expect(cfg.apiKey, 'sk-keep-9999');
    });

    test('writes the file with 600 permissions on POSIX', () {
      AiConfigIo.write(
        apiKey: 'sk-x',
        provider: AiProviderKind.gemini,
        home: home.path,
      );
      final file = File(AiConfigIo.defaultPath(home: home.path));
      expect(file.existsSync(), isTrue);
      if (!Platform.isWindows) {
        final mode = file.statSync().mode & 0x1FF; // permission bits
        expect(mode, 0x180, reason: 'expected rw------- (600)'); // 0600
      }
    });
  });

  group('describe', () {
    test('reports file source and masks key presence (no key leaked)', () {
      AiConfigIo.write(
        provider: AiProviderKind.gemini,
        model: 'gemini-test',
        apiKey: 'super-secret',
        mode: AgentMode.standard,
        home: home.path,
      );

      final d = AiConfigIo.describe(home: home.path, environment: noEnv);
      expect(d.provider, AiProviderKind.gemini);
      expect(d.providerFromEnv, isFalse);
      expect(d.model, 'gemini-test');
      expect(d.mode, AgentMode.standard);
      expect(d.keySet, isTrue);
      expect(d.keyFromEnv, isFalse);
      expect(d.keyEnvVar, 'GEMINI_API_KEY');
      expect(d.fileExists, isTrue);
    });

    test('reports key source as env when the provider env var is set', () {
      AiConfigIo.write(provider: AiProviderKind.anthropic, home: home.path);
      final d = AiConfigIo.describe(
        home: home.path,
        environment: const {'ANTHROPIC_API_KEY': 'sk-from-env'},
      );
      expect(d.provider, AiProviderKind.anthropic);
      expect(d.keySet, isTrue);
      expect(d.keyFromEnv, isTrue);
    });

    test('honors OMNYSHELL_AI_PROVIDER/OMNYSHELL_AI_MODEL overrides', () {
      final d = AiConfigIo.describe(
        home: home.path,
        environment: const {
          'OMNYSHELL_AI_PROVIDER': 'openai',
          'OMNYSHELL_AI_MODEL': 'gpt-from-env',
        },
      );
      expect(d.provider, AiProviderKind.openai);
      expect(d.providerFromEnv, isTrue);
      expect(d.model, 'gpt-from-env');
      expect(d.modelFromEnv, isTrue);
      expect(d.modelFromDefault, isFalse);
      expect(d.keySet, isFalse);
    });

    test('flags model/planner as default when the user has not set them', () {
      AiConfigIo.write(
        provider: AiProviderKind.anthropic,
        apiKey: 'k',
        home: home.path,
      );
      final d = AiConfigIo.describe(home: home.path, environment: noEnv);
      expect(d.model, 'claude-haiku-4-5');
      expect(d.modelFromDefault, isTrue);
      expect(d.modelFromEnv, isFalse);
      expect(d.plannerModel, 'claude-sonnet-4-6');
      expect(d.plannerFromDefault, isTrue);
    });

    test('a user-set model/planner is not flagged as default', () {
      AiConfigIo.write(
        provider: AiProviderKind.anthropic,
        apiKey: 'k',
        model: 'my-model',
        plannerModel: 'my-planner',
        home: home.path,
      );
      final d = AiConfigIo.describe(home: home.path, environment: noEnv);
      expect(d.model, 'my-model');
      expect(d.modelFromDefault, isFalse);
      expect(d.plannerModel, 'my-planner');
      expect(d.plannerFromDefault, isFalse);
    });
  });
}
