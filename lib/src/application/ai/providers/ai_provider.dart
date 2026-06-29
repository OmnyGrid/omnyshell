/// Provider-agnostic chat/tool-calling abstraction.
///
/// Each concrete provider (Anthropic, OpenAI, Gemini) maps these unified types
/// to its own HTTP API and back, so `AgentService` is written once against this
/// interface. All types here are pure data (no `dart:io`) and JSON-friendly.
library;

/// The author of an [AiMessage].
enum AiRole { system, user, assistant, tool }

/// A single message in the conversation.
///
/// Most messages carry [text]. An assistant turn that calls tools carries
/// [toolCalls]; a [AiRole.tool] message carries a single [toolResult] answering
/// one earlier call.
class AiMessage {
  const AiMessage({
    required this.role,
    this.text,
    this.toolCalls = const [],
    this.toolResult,
  });

  /// A plain system-prompt message.
  const AiMessage.system(String text) : this(role: AiRole.system, text: text);

  /// A plain user message.
  const AiMessage.user(String text) : this(role: AiRole.user, text: text);

  /// An assistant message, optionally with [text] and/or [toolCalls].
  const AiMessage.assistant({
    String? text,
    List<AiToolCall> toolCalls = const [],
  }) : this(role: AiRole.assistant, text: text, toolCalls: toolCalls);

  /// A tool-result message answering the call with [result]'s id.
  const AiMessage.tool(AiToolResult result)
    : this(role: AiRole.tool, toolResult: result);

  final AiRole role;
  final String? text;
  final List<AiToolCall> toolCalls;
  final AiToolResult? toolResult;
}

/// A tool the model is allowed to call. [parameters] is a JSON-Schema object.
class AiToolSpec {
  const AiToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

/// A single tool invocation requested by the model.
class AiToolCall {
  const AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// Provider-assigned call id, echoed back in the matching [AiToolResult].
  final String id;

  /// The tool name (e.g. `run_command`, `present_plan`).
  final String name;

  /// The decoded JSON arguments object.
  final Map<String, Object?> arguments;
}

/// The outcome of executing an [AiToolCall], fed back to the model.
class AiToolResult {
  const AiToolResult({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
  });

  /// The [AiToolCall.id] this result answers.
  final String callId;

  /// The tool name (some providers require it on the result).
  final String name;

  /// The textual result content (e.g. command output, or a blocked notice).
  final String content;

  /// Whether the result represents an error/refusal.
  final bool isError;
}

/// Why the model stopped this turn.
enum AiStopReason { endTurn, toolUse, maxTokens, other }

/// Token usage and latency for a single provider call.
///
/// All counts are best-effort: a provider that omits a usage field (or returns
/// an unexpected shape) reports `0` for it. [cachedInputTokens] is the subset of
/// [inputTokens] served from the provider's prompt cache (Anthropic
/// `cache_read_input_tokens`, OpenAI `prompt_tokens_details.cached_tokens`,
/// Gemini `cachedContentTokenCount`). [requestMs] is the wall-clock time of the
/// HTTP request, used to compute generation speed. Instances sum with `+` so the
/// agent loop can aggregate per-turn usage across a whole interaction.
class AiUsage {
  const AiUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.requestMs = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int requestMs;

  int get totalTokens => inputTokens + outputTokens;

  AiUsage operator +(AiUsage other) => AiUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
    requestMs: requestMs + other.requestMs,
  );

  /// The additive identity (all counts zero), used as an accumulator seed.
  static const zero = AiUsage();
}

/// Coerces a JSON value (provider usage counts may arrive as `int` or `num`)
/// into a non-negative token count, returning `0` for `null`/unexpected types.
int aiTokenCount(Object? value) {
  final n = value is num ? value.toInt() : 0;
  return n < 0 ? 0 : n;
}

/// Response header the Hub proxy sets to report the *upstream* provider request
/// duration in milliseconds.
///
/// When a browser client tunnels a provider call through the Hub, its local
/// stopwatch would also count the browser↔Hub round-trip, inflating the measured
/// generation time. The Hub measures the real upstream request itself and reports
/// it here so [aiRequestMs] can use it instead. Lower-cased to match how
/// `package:http` normalises header names.
const String kAiProxyElapsedMsHeader = 'x-omnyshell-proxy-elapsed-ms';

/// The request duration to record for a provider call: the Hub-reported upstream
/// time from [kAiProxyElapsedMsHeader] when present (proxied requests), otherwise
/// the locally measured [localMs].
int aiRequestMs(Map<String, String> headers, int localMs) {
  final raw = headers[kAiProxyElapsedMsHeader];
  final reported = raw == null ? null : int.tryParse(raw.trim());
  return (reported != null && reported >= 0) ? reported : localMs;
}

/// One assistant turn returned by a provider.
class AiResult {
  const AiResult({
    this.text,
    this.toolCalls = const [],
    this.stopReason = AiStopReason.endTurn,
    this.usage,
  });

  /// Assistant prose for this turn, if any.
  final String? text;

  /// Tool calls the model wants executed before continuing.
  final List<AiToolCall> toolCalls;

  /// Why the turn ended.
  final AiStopReason stopReason;

  /// Token usage and latency for this turn, or `null` if the provider did not
  /// report any (the agent then omits it from the run's stats line).
  final AiUsage? usage;

  /// Whether the model requested at least one tool call.
  bool get wantsTools => toolCalls.isNotEmpty;
}

/// Thrown when a provider request fails (network, auth, malformed response).
class AiProviderException implements Exception {
  const AiProviderException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'AiProviderException: $message'
      : 'AiProviderException($statusCode): $message';
}

/// A chat provider that supports tool calling.
abstract class AiProvider {
  /// Sends the conversation [messages] (the first may be a system message) and
  /// the available [tools], returning the model's next turn. [model] overrides
  /// the provider's configured default model for this call (used to switch
  /// between planner and executor models per phase); `null` uses the default.
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  });

  /// Releases any underlying resources (e.g. the HTTP client).
  void close();
}
