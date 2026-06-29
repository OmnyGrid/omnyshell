import 'package:command_shield/command_shield.dart'
    show Analyzer, CommandShield, KnowledgeRiskDetector, SecurityAnalyzer;
import 'package:http/http.dart' as http;

import '../ai/agent_mode.dart';
import '../ai/agent_style.dart';
import '../ai/ai_config_io.dart';
import '../ai/providers/provider_factory.dart';
import 'ai_command.dart';
import 'local_command.dart';

/// Registers the `:ai` command on a [LocalCommandRegistry] for the native CLI.
///
/// Loads [AiConfig] from env / `~/.omnyshell/ai.yaml` (see [AiConfigIo]). When a
/// usable provider+key is found, registers the live [AiCommand]; otherwise
/// registers a stub `:ai` that prints setup instructions, so the command always
/// exists and discovers itself in `:help`.
extension AiCommands on LocalCommandRegistry {
  void addAiCommand({String? home, bool color = false}) {
    final config = AiConfigIo.load(home: home);
    if (config == null) {
      register(_AiSetupCommand());
      return;
    }
    final provider = providerFor(config, http.Client());
    // Enable the knowledge-base risk detector on top of the structural defaults
    // so a command's knowledge-base risk also drives the verdict: a KB-`critical`
    // tool (e.g. `mkfs`, `dd of=/dev/...`) is hard-blocked in every `:ai` mode,
    // while `highRisk`/`mediumRisk` tools carry an accurate risk tag. Structural
    // detectors still provide wrapper look-through (`sudo mkfs …`) and pipe
    // detection (`curl … | sh`).
    final shield = CommandShield(
      analyzer: Analyzer(
        securityAnalyzer: SecurityAnalyzer(
          detectors: [
            ...SecurityAnalyzer.defaultDetectors,
            KnowledgeRiskDetector(),
          ],
        ),
      ),
    );
    register(
      AiCommand(
        config: config,
        provider: provider,
        shield: shield,
        style: color ? const AnsiAgentStyle() : const AgentStyle(),
        onModeChanged: (mode) => AiConfigIo.writeMode(mode, home: home),
        // Persist the language; an empty string clears it (load reads '' as
        // unset) since the writer skips null values.
        onLanguageChanged: (language) =>
            AiConfigIo.write(language: language ?? '', home: home),
      ),
    );
  }
}

/// Placeholder `:ai` shown when no provider/key is configured.
class _AiSetupCommand extends LocalCommand {
  @override
  String get name => 'ai';

  @override
  String get description =>
      'AI agent (not configured — run :ai for setup help)';

  @override
  Future<void> run(LocalCommandContext context, List<String> args) async {
    context.writeLine('ai: no provider configured.');
    context.writeLine('Set an API key via an environment variable:');
    context.writeLine('  ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY');
    context.writeLine('or create ~/.omnyshell/ai.yaml:');
    context.writeLine('  ai:');
    context.writeLine(
      '    provider: anthropic   # anthropic | openai | gemini',
    );
    context.writeLine('    model: claude-opus-4-8');
    context.writeLine('    apiKey: "sk-..."');
    context.writeLine('    mode: ${AgentMode.plan.wireName}');
  }
}
