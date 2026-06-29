import 'package:command_shield/command_shield.dart' show CommandShield;
import 'package:http/http.dart' as http;

import '../ai/agent_mode.dart';
import '../ai/agent_style.dart';
import '../ai/ai_config.dart';
import '../ai/providers/provider_factory.dart';
import 'ai_command.dart';
import 'local_command.dart';

/// Registers the `:ai` command on a [LocalCommandRegistry] for a browser
/// embedder.
///
/// Unlike the native `addAiCommand` (which loads `~/.omnyshell/ai.yaml` via
/// `dart:io`), the web client builds the [AiConfig] itself (e.g. from
/// `localStorage` and/or the Hub's advertised default) and supplies the
/// [httpClient] — typically a `HubHttpClient`, which routes provider calls
/// through the Hub so the browser need not reach AI APIs directly. This helper
/// just wires the provider, a default `command_shield`, and the [AiCommand], so
/// the web app does not depend on `command_shield`/`provider_factory` directly.
extension AiWebCommands on LocalCommandRegistry {
  /// Registers a live `:ai` command using [config] and [httpClient].
  void addAiCommand({
    required AiConfig config,
    required http.Client httpClient,
    AgentStyle style = const AgentStyle(),
    void Function(AgentMode mode)? onModeChanged,
    void Function(String? language)? onLanguageChanged,
  }) {
    register(
      AiCommand(
        config: config,
        provider: providerFor(config, httpClient),
        shield: CommandShield(),
        style: style,
        onModeChanged: onModeChanged,
        onLanguageChanged: onLanguageChanged,
      ),
    );
  }
}
