import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_config.dart';
import 'ai_provider.dart';

/// Talks to the Anthropic Messages API (`POST /v1/messages`) with tool use.
///
/// Wire format: `x-api-key` + `anthropic-version` headers; tools carry an
/// `input_schema`; the model returns `tool_use` content blocks and we feed
/// `tool_result` blocks back inside user messages.
class AnthropicProvider implements AiProvider {
  AnthropicProvider(this.config, this.client);

  final AiConfig config;
  final http.Client client;

  static const _version = '2023-06-01';

  Uri get _endpoint =>
      Uri.parse('${config.baseUrl ?? 'https://api.anthropic.com'}/v1/messages');

  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) async {
    final system = messages
        .where((m) => m.role == AiRole.system)
        .map((m) => m.text ?? '')
        .where((t) => t.isNotEmpty)
        .join('\n\n');

    final body = <String, Object?>{
      'model': model ?? config.model,
      'max_tokens': 4096,
      if (system.isNotEmpty) 'system': system,
      if (tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'name': t.name,
              'description': t.description,
              'input_schema': t.parameters,
            },
        ],
      'messages': _toMessages(messages),
    };

    final stopwatch = Stopwatch()..start();
    final http.Response res;
    try {
      res = await client.post(
        _endpoint,
        headers: {
          'content-type': 'application/json',
          'x-api-key': config.apiKey,
          'anthropic-version': _version,
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
    final content = (decoded['content'] as List?) ?? const [];
    final buf = StringBuffer();
    final calls = <AiToolCall>[];
    for (final block in content) {
      if (block is! Map) continue;
      switch (block['type']) {
        case 'text':
          buf.write(block['text'] as String? ?? '');
        case 'tool_use':
          calls.add(
            AiToolCall(
              id: block['id'] as String? ?? '',
              name: block['name'] as String? ?? '',
              arguments:
                  (block['input'] as Map?)?.cast<String, Object?>() ?? const {},
            ),
          );
      }
    }
    return AiResult(
      text: buf.isEmpty ? null : buf.toString(),
      toolCalls: calls,
      stopReason: _stopReason(decoded['stop_reason'] as String?),
      usage: _usage(
        decoded['usage'],
        aiRequestMs(res.headers, stopwatch.elapsedMilliseconds),
      ),
    );
  }

  /// Maps Anthropic's `usage` object to [AiUsage]. Cache-creation tokens are
  /// counted as input (they were sent to the model); cache-read tokens are the
  /// cached subset of input.
  AiUsage _usage(Object? raw, int requestMs) {
    final u = raw is Map ? raw : const {};
    final cacheRead = aiTokenCount(u['cache_read_input_tokens']);
    final cacheCreation = aiTokenCount(u['cache_creation_input_tokens']);
    return AiUsage(
      inputTokens: aiTokenCount(u['input_tokens']) + cacheRead + cacheCreation,
      outputTokens: aiTokenCount(u['output_tokens']),
      cachedInputTokens: cacheRead,
      requestMs: requestMs,
    );
  }

  /// Maps unified messages to Anthropic's `messages` array, merging consecutive
  /// tool results into a single user message (Anthropic requires that).
  List<Map<String, Object?>> _toMessages(List<AiMessage> messages) {
    final out = <Map<String, Object?>>[];
    List<Map<String, Object?>>? pendingToolResults;

    void flushToolResults() {
      if (pendingToolResults != null) {
        out.add({'role': 'user', 'content': pendingToolResults});
        pendingToolResults = null;
      }
    }

    for (final m in messages) {
      switch (m.role) {
        case AiRole.system:
          break; // handled as top-level system
        case AiRole.tool:
          final r = m.toolResult!;
          (pendingToolResults ??= []).add({
            'type': 'tool_result',
            'tool_use_id': r.callId,
            'content': r.content,
            if (r.isError) 'is_error': true,
          });
        case AiRole.user:
          flushToolResults();
          out.add({'role': 'user', 'content': m.text ?? ''});
        case AiRole.assistant:
          flushToolResults();
          final blocks = <Map<String, Object?>>[
            if (m.text != null && m.text!.isNotEmpty)
              {'type': 'text', 'text': m.text},
            for (final c in m.toolCalls)
              {
                'type': 'tool_use',
                'id': c.id,
                'name': c.name,
                'input': c.arguments,
              },
          ];
          out.add({'role': 'assistant', 'content': blocks});
      }
    }
    flushToolResults();
    return out;
  }

  AiStopReason _stopReason(String? raw) => switch (raw) {
    'tool_use' => AiStopReason.toolUse,
    'end_turn' => AiStopReason.endTurn,
    'max_tokens' => AiStopReason.maxTokens,
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
