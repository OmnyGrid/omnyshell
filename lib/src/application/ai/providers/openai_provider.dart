import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_config.dart';
import 'ai_provider.dart';

/// Talks to the OpenAI Chat Completions API (`POST /v1/chat/completions`) with
/// function tools. xAI is OpenAI-compatible, so pointing [AiConfig.baseUrl] at
/// `https://api.x.ai` reuses this provider unchanged.
class OpenAiProvider implements AiProvider {
  OpenAiProvider(this.config, this.client);

  final AiConfig config;
  final http.Client client;

  Uri get _endpoint => Uri.parse(
    '${config.baseUrl ?? 'https://api.openai.com'}/v1/chat/completions',
  );

  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) async {
    final body = <String, Object?>{
      'model': model ?? config.model,
      'messages': [for (final m in messages) ..._toMessages(m)],
      if (tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters,
              },
            },
        ],
    };

    final stopwatch = Stopwatch()..start();
    final http.Response res;
    try {
      res = await client.post(
        _endpoint,
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer ${config.apiKey}',
        },
        body: jsonEncode(body),
      );
    } catch (e) {
      throw AiProviderException('request failed: $e');
    } finally {
      stopwatch.stop();
    }

    if (res.statusCode != 200) {
      throw AiProviderException(
        _errorMessage(res.body),
        statusCode: res.statusCode,
      );
    }

    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw const AiProviderException('no choices in response');
    }
    final choice = choices.first as Map<String, Object?>;
    final message = choice['message'] as Map<String, Object?>? ?? const {};
    final text = message['content'] as String?;
    final calls = <AiToolCall>[];
    for (final tc in (message['tool_calls'] as List?) ?? const []) {
      if (tc is! Map) continue;
      final fn = tc['function'] as Map?;
      Map<String, Object?> args = const {};
      final raw = fn?['arguments'];
      if (raw is String && raw.isNotEmpty) {
        try {
          args = (jsonDecode(raw) as Map).cast<String, Object?>();
        } catch (_) {}
      }
      calls.add(
        AiToolCall(
          id: tc['id'] as String? ?? '',
          name: fn?['name'] as String? ?? '',
          arguments: args,
        ),
      );
    }
    return AiResult(
      text: (text == null || text.isEmpty) ? null : text,
      toolCalls: calls,
      stopReason: _stopReason(choice['finish_reason'] as String?),
      usage: _usage(
        decoded['usage'],
        aiRequestMs(res.headers, stopwatch.elapsedMilliseconds),
      ),
    );
  }

  /// Maps OpenAI's `usage` object to [AiUsage]. `prompt_tokens` already includes
  /// the cached subset reported under `prompt_tokens_details.cached_tokens`.
  AiUsage _usage(Object? raw, int requestMs) {
    final u = raw is Map ? raw : const {};
    final details = u['prompt_tokens_details'];
    return AiUsage(
      inputTokens: aiTokenCount(u['prompt_tokens']),
      outputTokens: aiTokenCount(u['completion_tokens']),
      cachedInputTokens: details is Map
          ? aiTokenCount(details['cached_tokens'])
          : 0,
      requestMs: requestMs,
    );
  }

  List<Map<String, Object?>> _toMessages(AiMessage m) {
    switch (m.role) {
      case AiRole.system:
        return [
          {'role': 'system', 'content': m.text ?? ''},
        ];
      case AiRole.user:
        return [
          {'role': 'user', 'content': m.text ?? ''},
        ];
      case AiRole.tool:
        final r = m.toolResult!;
        return [
          {'role': 'tool', 'tool_call_id': r.callId, 'content': r.content},
        ];
      case AiRole.assistant:
        return [
          {
            'role': 'assistant',
            'content': m.text ?? '',
            if (m.toolCalls.isNotEmpty)
              'tool_calls': [
                for (final c in m.toolCalls)
                  {
                    'id': c.id,
                    'type': 'function',
                    'function': {
                      'name': c.name,
                      'arguments': jsonEncode(c.arguments),
                    },
                  },
              ],
          },
        ];
    }
  }

  AiStopReason _stopReason(String? raw) => switch (raw) {
    'tool_calls' => AiStopReason.toolUse,
    'stop' => AiStopReason.endTurn,
    'length' => AiStopReason.maxTokens,
    _ => AiStopReason.other,
  };

  String _errorMessage(String body) {
    try {
      final m = jsonDecode(body) as Map<String, Object?>;
      final err = m['error'];
      if (err is Map && err['message'] is String) {
        return err['message'] as String;
      }
    } catch (_) {}
    return body;
  }

  @override
  void close() => client.close();
}
