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

/// One assistant turn returned by a provider.
class AiResult {
  const AiResult({
    this.text,
    this.toolCalls = const [],
    this.stopReason = AiStopReason.endTurn,
  });

  /// Assistant prose for this turn, if any.
  final String? text;

  /// Tool calls the model wants executed before continuing.
  final List<AiToolCall> toolCalls;

  /// Why the turn ended.
  final AiStopReason stopReason;

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
