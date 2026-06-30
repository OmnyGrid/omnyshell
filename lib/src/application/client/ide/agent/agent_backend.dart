import '../../../ai/providers/ai_provider.dart';

/// The working context handed to the AI agent: the file currently open in the
/// editor, or a directory selected in the tree. [label] is shown in the panel
/// title; [promptBlock] is injected into the system prompt.
class AgentContext {
  AgentContext({required this.label, required this.promptBlock});

  /// No specific context (the whole workspace).
  factory AgentContext.none() =>
      AgentContext(label: 'workspace', promptBlock: '');

  /// Context scoped to an open file and its [contents] (clipped to [maxChars]).
  factory AgentContext.file(
    String path,
    String contents, {
    int maxChars = 16000,
  }) {
    final clipped = contents.length > maxChars
        ? '${contents.substring(0, maxChars)}\n…(truncated)…'
        : contents;
    return AgentContext(
      label: path,
      promptBlock:
          'The user is working on this file.\n\nPath: $path\n\n```\n$clipped\n```',
    );
  }

  /// Context scoped to a directory and its entry names (clipped to [maxEntries]).
  factory AgentContext.directory(
    String path,
    List<String> entries, {
    int maxEntries = 200,
  }) {
    final shown = entries.length > maxEntries
        ? [
            ...entries.take(maxEntries),
            '…(${entries.length - maxEntries} more)',
          ]
        : entries;
    return AgentContext(
      label: '$path/',
      promptBlock:
          'The user is working in this directory.\n\nPath: $path\n\n'
          'Contents:\n${shown.isEmpty ? '(empty)' : shown.join('\n')}',
    );
  }

  final String label;
  final String promptBlock;
}

/// One completed exchange, kept so the conversation is multi-turn.
class AgentTurn {
  AgentTurn(this.user, this.assistant);
  final String user;
  final String assistant;
}

/// The workspace operations the code-assistant agent may perform. Implemented
/// by the IDE so edits flow through open editor tabs and everything is scoped to
/// the workspace root; faked in tests. All paths are workspace-relative or
/// absolute within the root.
abstract class AgentTools {
  /// Lists the entry names of directory [path].
  Future<List<String>> list(String path);

  /// Reads the UTF-8 contents of file [path].
  Future<String> read(String path);

  /// Creates or overwrites file [path] with [content].
  Future<void> write(String path, String content);

  /// Replaces the single occurrence of [oldString] in [path] with [newString].
  /// Throws if [oldString] is absent or appears more than once.
  Future<void> replace(String path, String oldString, String newString);

  /// Searches workspace files for [query], returning up to a bounded number of
  /// `relpath:line: text` matches.
  Future<List<String>> search(String query);

  /// Runs [command] in the workspace shell and returns its merged
  /// stdout/stderr plus an exit-status line.
  Future<String> run(String command);
}

/// Sends a prompt to an AI provider with the current [AgentContext] and returns
/// the assistant's reply. Abstracted so the IDE can inject a fake in tests
/// instead of hitting the network.
abstract class AgentBackend {
  /// Whether an AI provider is configured (an API key is present).
  bool get available;

  /// Human-readable setup help shown in the panel when [available] is false.
  String get unavailableReason;

  /// Sends [prompt] in [context], with prior [history] turns for continuity,
  /// and returns the assistant's reply text.
  Future<String> send({
    required String prompt,
    required AgentContext context,
    required List<AgentTurn> history,
  });

  /// Releases provider resources (e.g. the HTTP client). Safe to call once.
  void close() {}
}

/// The real backend: a code-assistant over an [AiProvider]. When [tools] is
/// supplied the model can read, write, edit (replace part of), list, search and
/// run commands in the workspace via an agentic tool-calling loop; without it,
/// it is a read-only chat assistant over the file/directory context.
class ProviderAgentBackend implements AgentBackend {
  ProviderAgentBackend(
    this._provider, {
    String? model,
    AgentTools? tools,
    int maxSteps = 12,
  }) : _model = model,
       _tools = tools,
       _maxSteps = maxSteps;

  final AiProvider _provider;
  final String? _model;
  final AgentTools? _tools;
  final int _maxSteps;

  @override
  bool get available => true;

  @override
  String get unavailableReason => '';

  @override
  Future<String> send({
    required String prompt,
    required AgentContext context,
    required List<AgentTurn> history,
  }) async {
    final messages = <AiMessage>[
      AiMessage.system(_systemPrompt(context)),
      for (final turn in history) ...[
        AiMessage.user(turn.user),
        AiMessage.assistant(text: turn.assistant),
      ],
      AiMessage.user(prompt),
    ];
    final specs = _tools == null ? const <AiToolSpec>[] : _toolSpecs;
    final transcript = StringBuffer();

    for (var step = 0; step < _maxSteps; step++) {
      final result = await _provider.chat(
        messages: messages,
        tools: specs,
        model: _model,
      );
      final text = result.text?.trim();
      if (text != null && text.isNotEmpty) transcript.writeln(text);
      if (!result.wantsTools) break;

      messages.add(
        AiMessage.assistant(text: result.text, toolCalls: result.toolCalls),
      );
      for (final call in result.toolCalls) {
        final outcome = await _runTool(call, transcript);
        messages.add(AiMessage.tool(outcome));
      }
    }

    final out = transcript.toString().trim();
    return out.isEmpty ? '(no response)' : out;
  }

  Future<AiToolResult> _runTool(AiToolCall call, StringBuffer notes) async {
    final tools = _tools!;
    String arg(String key) => call.arguments[key]?.toString() ?? '';
    AiToolResult ok(String content) =>
        AiToolResult(callId: call.id, name: call.name, content: content);
    AiToolResult err(String message) => AiToolResult(
      callId: call.id,
      name: call.name,
      content: message,
      isError: true,
    );
    try {
      switch (call.name) {
        case 'read_file':
          return ok(await tools.read(arg('path')));
        case 'write_file':
          await tools.write(arg('path'), arg('content'));
          notes.writeln('✎ wrote ${arg('path')}');
          return ok('wrote ${arg('path')}');
        case 'replace_in_file':
          await tools.replace(
            arg('path'),
            arg('old_string'),
            arg('new_string'),
          );
          notes.writeln('✎ edited ${arg('path')}');
          return ok('edited ${arg('path')}');
        case 'list_directory':
          return ok((await tools.list(arg('path'))).join('\n'));
        case 'search_text':
          final hits = await tools.search(arg('query'));
          return ok(hits.isEmpty ? '(no matches)' : hits.join('\n'));
        case 'run_command':
          notes.writeln('\$ ${arg('command')}');
          final output = await tools.run(arg('command'));
          if (output.trim().isNotEmpty) notes.writeln(output.trimRight());
          return ok(output);
        default:
          return err('unknown tool: ${call.name}');
      }
    } on Object catch (e) {
      notes.writeln('⚠ ${call.name} failed: $e');
      return err('$e');
    }
  }

  static const _strParam = {'type': 'string'};
  List<AiToolSpec> get _toolSpecs => const [
    AiToolSpec(
      name: 'read_file',
      description: 'Read a UTF-8 text file in the workspace.',
      parameters: {
        'type': 'object',
        'properties': {'path': _strParam},
        'required': ['path'],
      },
    ),
    AiToolSpec(
      name: 'write_file',
      description: 'Create or overwrite a file with the given content.',
      parameters: {
        'type': 'object',
        'properties': {'path': _strParam, 'content': _strParam},
        'required': ['path', 'content'],
      },
    ),
    AiToolSpec(
      name: 'replace_in_file',
      description:
          'Edit part of a file: replace an exact substring. old_string '
          'must occur exactly once in the file.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': _strParam,
          'old_string': _strParam,
          'new_string': _strParam,
        },
        'required': ['path', 'old_string', 'new_string'],
      },
    ),
    AiToolSpec(
      name: 'list_directory',
      description: 'List the entries of a directory in the workspace.',
      parameters: {
        'type': 'object',
        'properties': {'path': _strParam},
        'required': ['path'],
      },
    ),
    AiToolSpec(
      name: 'search_text',
      description: 'Search workspace files for a text query (grep-like).',
      parameters: {
        'type': 'object',
        'properties': {'query': _strParam},
        'required': ['query'],
      },
    ),
    AiToolSpec(
      name: 'run_command',
      description:
          'Run a shell command in the workspace (e.g. build, tests, git) '
          'and read its output.',
      parameters: {
        'type': 'object',
        'properties': {'command': _strParam},
        'required': ['command'],
      },
    ),
  ];

  String _systemPrompt(AgentContext context) {
    final base = _tools == null
        ? 'You are an AI coding assistant embedded in the OmnyShell terminal '
              'IDE. Answer concisely in plain text suitable for a narrow terminal '
              'panel; avoid heavy markdown.'
        : 'You are an AI code assistant embedded in the OmnyShell terminal IDE. '
              'You can read, write, and edit files, list directories, search, and '
              'run commands via the provided tools. Prefer replace_in_file for '
              'small edits and write_file for new or fully-rewritten files. Make '
              'the requested changes directly, then briefly summarise what you '
              'did. Keep prose concise and terminal-friendly.';
    return context.promptBlock.isEmpty
        ? base
        : '$base\n\n${context.promptBlock}';
  }

  @override
  void close() => _provider.close();
}

/// Stand-in used when no AI provider is configured: every send is rejected with
/// [unavailableReason].
class UnavailableAgentBackend implements AgentBackend {
  const UnavailableAgentBackend();

  @override
  bool get available => false;

  @override
  String get unavailableReason =>
      'No AI provider configured. Set ANTHROPIC_API_KEY (or OPENAI_API_KEY / '
      'GEMINI_API_KEY), or run :ai to configure ~/.omnyshell/ai.yaml.';

  @override
  Future<String> send({
    required String prompt,
    required AgentContext context,
    required List<AgentTurn> history,
  }) async => throw StateError('no AI provider configured');

  @override
  void close() {}
}
