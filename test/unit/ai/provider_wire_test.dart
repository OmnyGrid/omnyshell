@TestOn('vm')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnyshell/src/application/ai/ai_config.dart';
import 'package:omnyshell/src/application/ai/providers/ai_provider.dart';
import 'package:omnyshell/src/application/ai/providers/anthropic_provider.dart';
import 'package:omnyshell/src/application/ai/providers/gemini_provider.dart';
import 'package:omnyshell/src/application/ai/providers/openai_provider.dart';
import 'package:omnyshell/src/application/ai/providers/provider_factory.dart';
import 'package:test/test.dart';

/// Records the request a provider sent, so the wire format each API expects can
/// be asserted without talking to it.
class _Sent {
  http.Request? request;

  Uri get url => request!.url;
  Map<String, String> get headers => request!.headers;
  Map<String, Object?> get body =>
      jsonDecode(request!.body) as Map<String, Object?>;
  List<Object?> list(String key) => body[key] as List<Object?>;
}

/// A client that records the request and replies with [reply].
(http.Client, _Sent) _capturing(String reply, {int status = 200}) {
  final sent = _Sent();
  final client = MockClient((request) async {
    sent.request = request;
    return http.Response(
      reply,
      status,
      headers: const {'content-type': 'application/json'},
    );
  });
  return (client, sent);
}

/// A client whose every request fails at the transport level.
http.Client _broken() =>
    MockClient((_) async => throw const SocketishException());

/// Stands in for the socket errors `package:http` surfaces on a dead endpoint.
class SocketishException implements Exception {
  const SocketishException();
  @override
  String toString() => 'connection refused';
}

/// A client that records `close()` instead of sending anything.
class _CloseSpy extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() => closed = true;
}

const _tools = [
  AiToolSpec(
    name: 'run_command',
    description: 'Run a shell command',
    parameters: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string'},
      },
    },
  ),
];

AiConfig _config(AiProviderKind kind, {String? baseUrl}) => AiConfig(
  provider: kind,
  model: 'default-model',
  apiKey: 'secret-key',
  baseUrl: baseUrl,
);

void main() {
  group('AnthropicProvider', () {
    AnthropicProvider provider(http.Client client, {String? baseUrl}) =>
        AnthropicProvider(
          _config(AiProviderKind.anthropic, baseUrl: baseUrl),
          client,
        );

    test(
      'posts to /v1/messages with the API key and version headers',
      () async {
        final (client, sent) = _capturing('{"content":[]}');

        await provider(
          client,
        ).chat(messages: const [AiMessage.user('hi')], tools: const []);

        expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
        expect(sent.headers['x-api-key'], 'secret-key');
        expect(sent.headers['anthropic-version'], '2023-06-01');
        expect(sent.body['model'], 'default-model');
        expect(sent.body['max_tokens'], 4096);
      },
    );

    test('honours a baseUrl override and a per-call model', () async {
      final (client, sent) = _capturing('{"content":[]}');

      await provider(client, baseUrl: 'https://proxy.example').chat(
        messages: const [AiMessage.user('hi')],
        tools: const [],
        model: 'claude-other',
      );

      expect(sent.url.toString(), 'https://proxy.example/v1/messages');
      expect(sent.body['model'], 'claude-other');
    });

    test('hoists system messages out of the conversation, joined', () async {
      final (client, sent) = _capturing('{"content":[]}');

      await provider(client).chat(
        messages: const [
          AiMessage.system('be brief'),
          AiMessage.system(''),
          AiMessage.system('be kind'),
          AiMessage.user('hi'),
        ],
        tools: const [],
      );

      expect(sent.body['system'], 'be brief\n\nbe kind');
      expect(sent.list('messages'), [
        {'role': 'user', 'content': 'hi'},
      ], reason: 'system turns are not part of the messages array');
    });

    test('omits system and tools when there are none', () async {
      final (client, sent) = _capturing('{"content":[]}');

      await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(sent.body.containsKey('system'), isFalse);
      expect(sent.body.containsKey('tools'), isFalse);
    });

    test('sends tools with an input_schema', () async {
      final (client, sent) = _capturing('{"content":[]}');

      await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: _tools);

      expect(sent.list('tools').single, {
        'name': 'run_command',
        'description': 'Run a shell command',
        'input_schema': _tools.single.parameters,
      });
    });

    test('merges consecutive tool results into one user message', () async {
      final (client, sent) = _capturing('{"content":[]}');

      await provider(client).chat(
        messages: const [
          AiMessage.user('do it'),
          AiMessage.assistant(
            text: 'calling',
            toolCalls: [
              AiToolCall(id: 'c1', name: 'run_command', arguments: {'a': 1}),
              AiToolCall(id: 'c2', name: 'run_command', arguments: {}),
            ],
          ),
          AiMessage.tool(
            AiToolResult(callId: 'c1', name: 'run_command', content: 'ok'),
          ),
          AiMessage.tool(
            AiToolResult(
              callId: 'c2',
              name: 'run_command',
              content: 'blocked',
              isError: true,
            ),
          ),
        ],
        tools: const [],
      );

      final messages = sent.list('messages');
      expect(messages, hasLength(3));
      expect((messages[1] as Map)['role'], 'assistant');
      expect((messages[1] as Map)['content'], [
        {'type': 'text', 'text': 'calling'},
        {
          'type': 'tool_use',
          'id': 'c1',
          'name': 'run_command',
          'input': {'a': 1},
        },
        {
          'type': 'tool_use',
          'id': 'c2',
          'name': 'run_command',
          'input': <String, Object?>{},
        },
      ]);
      // Anthropic requires the two results to arrive as one user turn.
      expect((messages[2] as Map)['role'], 'user');
      expect((messages[2] as Map)['content'], [
        {'type': 'tool_result', 'tool_use_id': 'c1', 'content': 'ok'},
        {
          'type': 'tool_result',
          'tool_use_id': 'c2',
          'content': 'blocked',
          'is_error': true,
        },
      ]);
    });

    test('flushes pending tool results before the next user turn', () async {
      final (client, sent) = _capturing('{"content":[]}');

      await provider(client).chat(
        messages: const [
          AiMessage.tool(AiToolResult(callId: 'c1', name: 't', content: 'ok')),
          AiMessage.user('and now this'),
        ],
        tools: const [],
      );

      final messages = sent.list('messages');
      expect(messages, hasLength(2));
      expect((messages[0] as Map)['content'], isA<List<Object?>>());
      expect((messages[1] as Map)['content'], 'and now this');
    });

    test('reads text and tool_use blocks, ignoring anything else', () async {
      final (client, _) = _capturing(
        '{"content":['
        '{"type":"text","text":"one "},'
        '"not-a-block",'
        '{"type":"thinking","thinking":"hmm"},'
        '{"type":"text","text":"two"},'
        '{"type":"tool_use","id":"c1","name":"run_command",'
        '"input":{"command":"ls"}}],'
        '"stop_reason":"tool_use"}',
      );

      final result = await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(result.text, 'one two');
      expect(result.stopReason, AiStopReason.toolUse);
      expect(result.wantsTools, isTrue);
      expect(result.toolCalls.single.id, 'c1');
      expect(result.toolCalls.single.name, 'run_command');
      expect(result.toolCalls.single.arguments, {'command': 'ls'});
    });

    test('defaults a tool_use block missing its fields', () async {
      final (client, _) = _capturing(
        '{"content":[{"type":"tool_use"}],"stop_reason":"tool_use"}',
      );

      final call = (await provider(client).chat(
        messages: const [AiMessage.user('hi')],
        tools: const [],
      )).toolCalls.single;

      expect(call.id, '');
      expect(call.name, '');
      expect(call.arguments, isEmpty);
    });

    test('reports no text when the model returned none', () async {
      final (client, _) = _capturing('{"content":[],"stop_reason":"end_turn"}');

      final result = await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(result.text, isNull);
      expect(result.stopReason, AiStopReason.endTurn);
    });

    test('maps every stop reason', () async {
      for (final (wire, expected) in const [
        ('tool_use', AiStopReason.toolUse),
        ('end_turn', AiStopReason.endTurn),
        ('max_tokens', AiStopReason.maxTokens),
        ('refusal', AiStopReason.other),
        (null, AiStopReason.other),
      ]) {
        final (client, _) = _capturing(
          '{"content":[],"stop_reason":${jsonEncode(wire)}}',
        );

        final result = await provider(
          client,
        ).chat(messages: const [AiMessage.user('hi')], tools: const []);

        expect(result.stopReason, expected, reason: 'stop_reason $wire');
      }
    });

    test('turns an error response into the provider message', () async {
      final (client, _) = _capturing(
        '{"error":{"type":"not_found_error","message":"model not found"}}',
        status: 404,
      );

      await expectLater(
        provider(
          client,
        ).chat(messages: const [AiMessage.user('hi')], tools: const []),
        throwsA(
          isA<AiProviderException>()
              .having((e) => e.message, 'message', 'model not found')
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => '$e', 'toString', contains('(404)')),
        ),
      );
    });

    test('falls back to the raw body when the error is not JSON', () async {
      final (client, _) = _capturing('<html>502</html>', status: 502);

      await expectLater(
        provider(
          client,
        ).chat(messages: const [AiMessage.user('hi')], tools: const []),
        throwsA(
          isA<AiProviderException>().having(
            (e) => e.message,
            'message',
            '<html>502</html>',
          ),
        ),
      );
    });

    test('wraps a transport failure', () async {
      await expectLater(
        provider(
          _broken(),
        ).chat(messages: const [AiMessage.user('hi')], tools: const []),
        throwsA(
          isA<AiProviderException>()
              .having((e) => e.message, 'message', startsWith('request failed'))
              .having((e) => e.statusCode, 'statusCode', isNull),
        ),
      );
    });

    test('closing the provider closes the HTTP client', () {
      final spy = _CloseSpy();
      AnthropicProvider(_config(AiProviderKind.anthropic), spy).close();
      expect(spy.closed, isTrue);
    });
  });

  group('OpenAiProvider', () {
    OpenAiProvider provider(http.Client client, {String? baseUrl}) =>
        OpenAiProvider(
          _config(AiProviderKind.openai, baseUrl: baseUrl),
          client,
        );

    const emptyReply =
        '{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}';

    test(
      'posts to the chat completions endpoint with a bearer token',
      () async {
        final (client, sent) = _capturing(emptyReply);

        await provider(
          client,
        ).chat(messages: const [AiMessage.user('hi')], tools: const []);

        expect(
          sent.url.toString(),
          'https://api.openai.com/v1/chat/completions',
        );
        expect(sent.headers['authorization'], 'Bearer secret-key');
        expect(sent.body['model'], 'default-model');
      },
    );

    test('honours a baseUrl override (the xAI-compatible path)', () async {
      final (client, sent) = _capturing(emptyReply);

      await provider(client, baseUrl: 'https://api.x.ai').chat(
        messages: const [AiMessage.user('hi')],
        tools: const [],
        model: 'grok',
      );

      expect(sent.url.toString(), 'https://api.x.ai/v1/chat/completions');
      expect(sent.body['model'], 'grok');
    });

    test('maps every role onto the messages array', () async {
      final (client, sent) = _capturing(emptyReply);

      await provider(client).chat(
        messages: const [
          AiMessage.system('be brief'),
          AiMessage.user('do it'),
          AiMessage.assistant(
            text: 'calling',
            toolCalls: [
              AiToolCall(
                id: 'c1',
                name: 'run_command',
                arguments: {'command': 'ls'},
              ),
            ],
          ),
          AiMessage.tool(
            AiToolResult(callId: 'c1', name: 'run_command', content: 'ok'),
          ),
        ],
        tools: _tools,
      );

      expect(sent.list('messages'), [
        {'role': 'system', 'content': 'be brief'},
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': 'calling',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {
                'name': 'run_command',
                'arguments': '{"command":"ls"}',
              },
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': 'ok'},
      ]);
      expect(sent.list('tools').single, {
        'type': 'function',
        'function': {
          'name': 'run_command',
          'description': 'Run a shell command',
          'parameters': _tools.single.parameters,
        },
      });
    });

    test('omits tool_calls from an assistant turn that made none', () async {
      final (client, sent) = _capturing(emptyReply);

      await provider(client).chat(
        messages: const [AiMessage.assistant(text: 'just talking')],
        tools: const [],
      );

      expect(
        (sent.list('messages').single as Map).containsKey('tool_calls'),
        isFalse,
      );
    });

    test('parses tool calls and decodes their arguments', () async {
      final (client, _) = _capturing(
        '{"choices":[{"message":{"content":"on it","tool_calls":['
        '{"id":"c1","function":{"name":"run_command",'
        '"arguments":"{\\"command\\":\\"ls\\"}"}}]},'
        '"finish_reason":"tool_calls"}]}',
      );

      final result = await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(result.text, 'on it');
      expect(result.stopReason, AiStopReason.toolUse);
      expect(result.toolCalls.single.arguments, {'command': 'ls'});
    });

    test('survives tool-call arguments that are not valid JSON', () async {
      final (client, _) = _capturing(
        '{"choices":[{"message":{"tool_calls":['
        '"not-a-call",'
        '{"function":{"arguments":"{oops"}},'
        '{"id":"c2","function":{"name":"run_command","arguments":""}}]},'
        '"finish_reason":"tool_calls"}]}',
      );

      final calls = (await provider(client).chat(
        messages: const [AiMessage.user('hi')],
        tools: const [],
      )).toolCalls;

      expect(calls, hasLength(2), reason: 'the non-map entry is skipped');
      expect(calls[0].id, '');
      expect(calls[0].name, '');
      expect(calls[0].arguments, isEmpty);
      expect(calls[1].id, 'c2');
      expect(calls[1].arguments, isEmpty);
    });

    test('reports no text for an empty completion', () async {
      final (client, _) = _capturing(emptyReply);

      final result = await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(result.text, isNull);
      expect(result.toolCalls, isEmpty);
      expect(result.stopReason, AiStopReason.endTurn);
    });

    test('maps every finish reason', () async {
      for (final (wire, expected) in const [
        ('tool_calls', AiStopReason.toolUse),
        ('stop', AiStopReason.endTurn),
        ('length', AiStopReason.maxTokens),
        ('content_filter', AiStopReason.other),
        (null, AiStopReason.other),
      ]) {
        final (client, _) = _capturing(
          '{"choices":[{"message":{},"finish_reason":${jsonEncode(wire)}}]}',
        );

        final result = await provider(
          client,
        ).chat(messages: const [AiMessage.user('hi')], tools: const []);

        expect(result.stopReason, expected, reason: 'finish_reason $wire');
      }
    });

    test('rejects a response with no choices', () async {
      for (final body in const ['{"choices":[]}', '{}']) {
        final (client, _) = _capturing(body);

        await expectLater(
          provider(
            client,
          ).chat(messages: const [AiMessage.user('hi')], tools: const []),
          throwsA(
            isA<AiProviderException>().having(
              (e) => e.message,
              'message',
              'no choices in response',
            ),
          ),
        );
      }
    });

    test('turns an error response into the provider message', () async {
      final (client, _) = _capturing(
        '{"error":{"message":"invalid api key","code":"invalid_api_key"}}',
        status: 401,
      );

      await expectLater(
        provider(
          client,
        ).chat(messages: const [AiMessage.user('hi')], tools: const []),
        throwsA(
          isA<AiProviderException>()
              .having((e) => e.message, 'message', 'invalid api key')
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('wraps a transport failure', () async {
      await expectLater(
        provider(
          _broken(),
        ).chat(messages: const [AiMessage.user('hi')], tools: const []),
        throwsA(
          isA<AiProviderException>().having(
            (e) => e.message,
            'message',
            startsWith('request failed'),
          ),
        ),
      );
    });

    test('closing the provider closes the HTTP client', () {
      final spy = _CloseSpy();
      OpenAiProvider(_config(AiProviderKind.openai), spy).close();
      expect(spy.closed, isTrue);
    });
  });

  group('GeminiProvider', () {
    GeminiProvider provider(http.Client client, {String? baseUrl}) =>
        GeminiProvider(
          _config(AiProviderKind.gemini, baseUrl: baseUrl),
          client,
        );

    const emptyReply = '{"candidates":[{"content":{"parts":[]}}]}';

    test('puts the model in the path and the key in the query', () async {
      final (client, sent) = _capturing(emptyReply);

      await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(sent.url.path, '/v1beta/models/default-model:generateContent');
      expect(sent.url.host, 'generativelanguage.googleapis.com');
      expect(sent.url.queryParameters['key'], 'secret-key');
    });

    test('honours a baseUrl override and a per-call model', () async {
      final (client, sent) = _capturing(emptyReply);

      await provider(client, baseUrl: 'https://proxy.example').chat(
        messages: const [AiMessage.user('hi')],
        tools: const [],
        model: 'gemini-other',
      );

      expect(sent.url.host, 'proxy.example');
      expect(sent.url.path, '/v1beta/models/gemini-other:generateContent');
    });

    test('hoists system turns into system_instruction', () async {
      final (client, sent) = _capturing(emptyReply);

      await provider(client).chat(
        messages: const [
          AiMessage.system('be brief'),
          AiMessage.system('be kind'),
          AiMessage.user('hi'),
        ],
        tools: const [],
      );

      expect(sent.body['system_instruction'], {
        'parts': [
          {'text': 'be brief\n\nbe kind'},
        ],
      });
      expect(sent.list('contents'), hasLength(1));
    });

    test('maps the conversation onto contents', () async {
      final (client, sent) = _capturing(emptyReply);

      await provider(client).chat(
        messages: const [
          AiMessage.user('do it'),
          AiMessage.assistant(
            text: 'calling',
            toolCalls: [
              AiToolCall(
                id: 'run_command#0',
                name: 'run_command',
                arguments: {'command': 'ls'},
              ),
            ],
          ),
          AiMessage.tool(
            AiToolResult(
              callId: 'ignored',
              name: 'run_command',
              content: 'ok',
              isError: true,
            ),
          ),
        ],
        tools: _tools,
      );

      expect(sent.list('contents'), [
        {
          'role': 'user',
          'parts': [
            {'text': 'do it'},
          ],
        },
        {
          'role': 'model',
          'parts': [
            {'text': 'calling'},
            {
              'functionCall': {
                'name': 'run_command',
                'args': {'command': 'ls'},
              },
            },
          ],
        },
        {
          'role': 'user',
          'parts': [
            {
              // Matched back by name: Gemini function calls carry no id.
              'functionResponse': {
                'name': 'run_command',
                'response': {'output': 'ok', 'is_error': true},
              },
            },
          ],
        },
      ]);
      expect(
        (sent.list('tools').single as Map)['function_declarations'],
        hasLength(1),
      );
    });

    test('parses function calls and numbers their synthetic ids', () async {
      final (client, _) = _capturing(
        '{"candidates":[{"content":{"parts":['
        '{"text":"one "},'
        '"not-a-part",'
        '{"functionCall":{"name":"run_command","args":{"command":"ls"}}},'
        '{"functionCall":{"name":"run_command"}},'
        '{"text":"two"}]}}]}',
      );

      final result = await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(result.text, 'one two');
      expect(result.stopReason, AiStopReason.toolUse);
      expect(result.toolCalls.map((c) => c.id), [
        'run_command#0',
        'run_command#1',
      ]);
      expect(result.toolCalls.first.arguments, {'command': 'ls'});
      expect(result.toolCalls.last.arguments, isEmpty);
    });

    test('ends the turn when no function call came back', () async {
      final (client, _) = _capturing(
        '{"candidates":[{"content":{"parts":[{"text":"just prose"}]}}]}',
      );

      final result = await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(result.text, 'just prose');
      expect(result.stopReason, AiStopReason.endTurn);
    });

    test('reports no text for a candidate with no parts', () async {
      final (client, _) = _capturing('{"candidates":[{}]}');

      final result = await provider(
        client,
      ).chat(messages: const [AiMessage.user('hi')], tools: const []);

      expect(result.text, isNull);
      expect(result.toolCalls, isEmpty);
    });

    test('rejects a response with no candidates', () async {
      for (final body in const ['{"candidates":[]}', '{}']) {
        final (client, _) = _capturing(body);

        await expectLater(
          provider(
            client,
          ).chat(messages: const [AiMessage.user('hi')], tools: const []),
          throwsA(
            isA<AiProviderException>().having(
              (e) => e.message,
              'message',
              'no candidates in response',
            ),
          ),
        );
      }
    });

    test('turns an error response into the provider message', () async {
      final (client, _) = _capturing(
        '{"error":{"code":429,"message":"quota exceeded"}}',
        status: 429,
      );

      await expectLater(
        provider(
          client,
        ).chat(messages: const [AiMessage.user('hi')], tools: const []),
        throwsA(
          isA<AiProviderException>()
              .having((e) => e.message, 'message', 'quota exceeded')
              .having((e) => e.statusCode, 'statusCode', 429),
        ),
      );
    });

    test('wraps a transport failure', () async {
      await expectLater(
        provider(
          _broken(),
        ).chat(messages: const [AiMessage.user('hi')], tools: const []),
        throwsA(
          isA<AiProviderException>().having(
            (e) => e.message,
            'message',
            startsWith('request failed'),
          ),
        ),
      );
    });

    test('closing the provider closes the HTTP client', () {
      final spy = _CloseSpy();
      GeminiProvider(_config(AiProviderKind.gemini), spy).close();
      expect(spy.closed, isTrue);
    });
  });

  group('providerFor', () {
    final client = MockClient((_) async => http.Response('{}', 200));

    test('builds the provider each kind names', () {
      expect(
        providerFor(_config(AiProviderKind.anthropic), client),
        isA<AnthropicProvider>(),
      );
      expect(
        providerFor(_config(AiProviderKind.openai), client),
        isA<OpenAiProvider>(),
      );
      expect(
        providerFor(_config(AiProviderKind.gemini), client),
        isA<GeminiProvider>(),
      );
    });
  });
}
