import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_config.dart';
import 'ai_provider.dart';

/// Talks to Google's Generative Language API
/// (`POST /v1beta/models/{model}:generateContent`) with function declarations.
///
/// Gemini function calls carry no id and are matched back by function *name*,
/// so [AiToolResult.name] (not [AiToolResult.callId]) is used when building the
/// `functionResponse` parts.
class GeminiProvider implements AiProvider {
  GeminiProvider(this.config, this.client);

  final AiConfig config;
  final http.Client client;

  Uri _endpoint(String model) => Uri.parse(
    '${config.baseUrl ?? 'https://generativelanguage.googleapis.com'}'
    '/v1beta/models/$model:generateContent?key=${config.apiKey}',
  );

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
      if (system.isNotEmpty)
        'system_instruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': _toContents(messages),
      if (tools.isNotEmpty)
        'tools': [
          {
            'function_declarations': [
              for (final t in tools)
                {
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.parameters,
                },
            ],
          },
        ],
    };

    final http.Response res;
    try {
      res = await client.post(
        _endpoint(model ?? config.model),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (e) {
      throw AiProviderException('request failed: $e');
    }

    if (res.statusCode != 200) {
      throw AiProviderException(
        _errorMessage(res.body),
        statusCode: res.statusCode,
      );
    }

    final decoded = jsonDecode(res.body) as Map<String, Object?>;
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw const AiProviderException('no candidates in response');
    }
    final candidate = candidates.first as Map<String, Object?>;
    final parts = (candidate['content'] as Map?)?['parts'] as List? ?? const [];

    final buf = StringBuffer();
    final calls = <AiToolCall>[];
    var i = 0;
    for (final part in parts) {
      if (part is! Map) continue;
      if (part['text'] is String) {
        buf.write(part['text'] as String);
      } else if (part['functionCall'] is Map) {
        final fc = part['functionCall'] as Map;
        final name = fc['name'] as String? ?? '';
        calls.add(
          AiToolCall(
            id: '$name#${i++}',
            name: name,
            arguments:
                (fc['args'] as Map?)?.cast<String, Object?>() ?? const {},
          ),
        );
      }
    }
    return AiResult(
      text: buf.isEmpty ? null : buf.toString(),
      toolCalls: calls,
      stopReason: calls.isNotEmpty
          ? AiStopReason.toolUse
          : AiStopReason.endTurn,
    );
  }

  List<Map<String, Object?>> _toContents(List<AiMessage> messages) {
    final out = <Map<String, Object?>>[];
    for (final m in messages) {
      switch (m.role) {
        case AiRole.system:
          break; // handled via system_instruction
        case AiRole.user:
          out.add({
            'role': 'user',
            'parts': [
              {'text': m.text ?? ''},
            ],
          });
        case AiRole.tool:
          final r = m.toolResult!;
          out.add({
            'role': 'user',
            'parts': [
              {
                'functionResponse': {
                  'name': r.name,
                  'response': {'output': r.content, 'is_error': r.isError},
                },
              },
            ],
          });
        case AiRole.assistant:
          out.add({
            'role': 'model',
            'parts': [
              if (m.text != null && m.text!.isNotEmpty) {'text': m.text},
              for (final c in m.toolCalls)
                {
                  'functionCall': {'name': c.name, 'args': c.arguments},
                },
            ],
          });
      }
    }
    return out;
  }

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
