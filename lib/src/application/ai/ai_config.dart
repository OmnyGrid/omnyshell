import 'agent_mode.dart';

/// Which phase of the agent loop a model request belongs to, used to pick the
/// model via [AiConfig.modelFor].
enum AgentPhase {
  /// Investigation / read-only probing / deciding the next action. Uses the
  /// (usually stronger) planner model.
  planning,

  /// Carrying out a mutating command or running an approved plan. Uses the
  /// (usually cheaper) executor model.
  executing,
}

/// The AI provider an [AiConfig] talks to.
///
/// xAI is intentionally omitted from v1; because its API is OpenAI-compatible it
/// can later be served by the OpenAI provider pointed at a different `baseUrl`.
enum AiProviderKind {
  anthropic,
  openai,
  gemini;

  /// The token used in `ai.yaml` (its lowercase name).
  String get wireName => name;

  /// Decodes a provider token, returning `null` for unknown values.
  static AiProviderKind? tryParse(String? value) => switch (value?.trim()) {
    'anthropic' => AiProviderKind.anthropic,
    'openai' => AiProviderKind.openai,
    'gemini' => AiProviderKind.gemini,
    _ => null,
  };
}

/// Immutable AI configuration: which provider/model to use, the API key, the
/// default agent mode and loop bounds.
///
/// Pure data with no I/O so it compiles to JavaScript; the native loader that
/// reads env vars / `~/.omnyshell/ai.yaml` lives in `ai_config_io.dart`.
class AiConfig {
  const AiConfig({
    required this.provider,
    required this.model,
    required this.apiKey,
    this.plannerModel,
    this.executorModel,
    this.baseUrl,
    this.defaultMode = AgentMode.plan,
    this.language,
    this.maxSteps = 24,
  });

  /// The provider to send requests to.
  final AiProviderKind provider;

  /// The shared/default model id (e.g. a Claude/GPT/Gemini model), used by both
  /// phases unless [plannerModel]/[executorModel] override it. Kept in config
  /// rather than hardcoded so it does not go stale.
  final String model;

  /// Optional stronger model for the planning phase. Falls back to [model].
  final String? plannerModel;

  /// Optional cheaper model for the executing phase. Falls back to [model].
  final String? executorModel;

  /// The API key used to authenticate with [provider].
  final String apiKey;

  /// Overrides the provider's default API base URL (e.g. a proxy or an
  /// OpenAI-compatible endpoint). `null` uses the provider default.
  final String? baseUrl;

  /// The agent mode used when the user does not override it per invocation.
  final AgentMode defaultMode;

  /// The language the agent replies in (free-form, e.g. `portuguese`, `es`),
  /// woven into the system prompt. `null` lets the model choose (usually the
  /// user's language or English). Shell commands/output are unaffected.
  final String? language;

  /// The maximum number of provider round-trips before the agent loop stops,
  /// guarding against runaway loops and token spend.
  final int maxSteps;

  /// The model to use for [phase], falling back to [model] when the per-phase
  /// model is unset.
  String modelFor(AgentPhase phase) => switch (phase) {
    AgentPhase.planning => plannerModel ?? model,
    AgentPhase.executing => executorModel ?? model,
  };

  /// Returns a copy with the given fields replaced.
  AiConfig copyWith({
    AiProviderKind? provider,
    String? model,
    String? apiKey,
    String? plannerModel,
    String? executorModel,
    String? baseUrl,
    AgentMode? defaultMode,
    String? language,
    int? maxSteps,
  }) => AiConfig(
    provider: provider ?? this.provider,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    plannerModel: plannerModel ?? this.plannerModel,
    executorModel: executorModel ?? this.executorModel,
    baseUrl: baseUrl ?? this.baseUrl,
    defaultMode: defaultMode ?? this.defaultMode,
    language: language ?? this.language,
    maxSteps: maxSteps ?? this.maxSteps,
  );
}
