import 'package:command_shield/command_shield.dart';
import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// A provider stub — the help/usage paths never call it.
class _FakeProvider implements AiProvider {
  bool closed = false;

  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) async => const AiResult(stopReason: AiStopReason.endTurn);

  @override
  void close() => closed = true;
}

/// A provider that replays [_script], one [AiResult] per `chat` call, and
/// records the messages of every call.
class _ScriptedProvider implements AiProvider {
  _ScriptedProvider(this._script);

  final List<AiResult> _script;
  final List<List<AiMessage>> calls = [];

  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) async {
    calls.add(List.of(messages));
    return _script[calls.length - 1];
  }

  @override
  void close() {}

  /// The system prompt of the first request.
  String get systemPrompt =>
      calls.first.firstWhere((m) => m.role == AiRole.system).text!;

  /// The tool result fed back in request [call] (its last message).
  AiToolResult toolResultIn(int call) => calls[call].last.toolResult!;
}

/// A console double: records every line and prompt, and answers prompts from
/// a queue ('' once exhausted, which ends the agent's follow-up chat).
class _Console {
  _Console([
    List<String> answers = const [],
    this.pressCtrlCWhileRunning = false,
  ]) : _answers = List.of(answers);

  final List<String> _answers;

  /// Simulates Ctrl-C while a session command runs, via the handler the
  /// command installed with `onInterruptRequest`.
  final bool pressCtrlCWhileRunning;
  final List<String> lines = [];
  final List<String> prompts = [];

  /// Commands run in the live session, in order.
  final List<String> ran = [];

  /// Every value handed to `onInterruptRequest`, in order.
  final List<void Function()?> interruptHandlers = [];

  String get text => lines.join('\n');

  Future<String> readLine(String prompt) async {
    prompts.add(prompt);
    return _answers.isEmpty ? '' : _answers.removeAt(0);
  }

  Future<SessionCommandResult> runInSession(String command) async {
    ran.add(command);
    if (pressCtrlCWhileRunning) interruptHandlers.last!();
    return const SessionCommandResult(exitCode: null, output: 'file.txt');
  }
}

LocalCommandContext _ctx(
  List<String> out, {
  _Console? console,
  bool interactive = true,
  bool liveSession = true,
  ShellFamily? shellFamily,
  String? cwd,
}) => LocalCommandContext(
  client: ClientRuntime(
    ClientConfig(
      hubUri: Uri.parse('wss://localhost:1/'),
      credentials: const TokenCredentialProvider(
        principal: 'tester',
        token: 'tok',
      ),
    ),
  ),
  node: NodeDescriptor(
    id: NodeId('n1'),
    displayName: 'n1',
    platform: const PlatformInfo(
      os: 'linux',
      arch: 'x64',
      agentVersion: '1.0.0',
      hostname: 'host',
    ),
    online: true,
  ),
  startedAt: DateTime.now(),
  writeLine: out.add,
  shellFamily: shellFamily,
  currentRemoteCwd: cwd == null ? null : () => cwd,
  readLine: interactive ? console?.readLine : null,
  runInSession: liveSession ? console?.runInSession : null,
  onInterruptRequest: console?.interruptHandlers.add,
);

const _config = AiConfig(
  provider: AiProviderKind.anthropic,
  model: 'm',
  apiKey: 'k',
);

AiToolCall _runCmd(String command) => AiToolCall(
  id: 'c-$command',
  name: 'run_command',
  arguments: {'command': command},
);

AiResult _tools(List<AiToolCall> calls) =>
    AiResult(toolCalls: calls, stopReason: AiStopReason.toolUse);

AiResult _say(String text) => AiResult(text: text);

const _plan = AiToolCall(
  id: 'p1',
  name: 'present_plan',
  arguments: {
    'summary': 'Make the dir',
    'steps': [
      {'command': 'mkdir d', 'explanation': 'create it'},
    ],
  },
);

void main() {
  AiCommand command({
    AiConfig config = _config,
    AiProvider? provider,
    void Function(AgentMode)? onModeChanged,
    void Function(String?)? onLanguageChanged,
  }) => AiCommand(
    config: config,
    provider: provider ?? _FakeProvider(),
    shield: CommandShield(),
    onModeChanged: onModeChanged,
    onLanguageChanged: onLanguageChanged,
  );

  group(':ai help', () {
    for (final arg in ['-h', '--help', 'help']) {
      test(':ai $arg prints usage without invoking the agent', () async {
        final out = <String>[];
        await command().run(_ctx(out), [arg]);
        final text = out.join('\n');
        expect(text, contains('Usage:'));
        expect(text, contains(':ai <prompt>'));
        expect(text, contains(':ai -h | --help'));
      });
    }

    test(':ai with no args also prints usage', () async {
      final out = <String>[];
      await command().run(_ctx(out), []);
      expect(out.join('\n'), contains('Usage:'));
    });
  });

  group(':ai status', () {
    test('shows provider, model, mode and the default language', () async {
      final out = <String>[];
      await command().run(_ctx(out), ['status']);
      expect(out, [
        'ai: anthropic / m (mode: plan)',
        '  language: (model default)',
      ]);
    });

    test('lists per-phase models and the configured language', () async {
      final out = <String>[];
      await command(
        config: _config.copyWith(
          plannerModel: 'big',
          executorModel: 'small',
          explainerModel: 'tiny',
          language: 'portuguese',
          defaultMode: AgentMode.auto,
        ),
      ).run(_ctx(out), ['status']);
      expect(out, [
        'ai: anthropic / m (mode: auto)',
        '  planner:  big',
        '  executor: small',
        '  explainer: tiny',
        '  language: portuguese',
      ]);
    });
  });

  group(':ai mode', () {
    test('sets the session default and reports the change', () async {
      final changes = <AgentMode>[];
      final cmd = command(onModeChanged: changes.add);
      final out = <String>[];
      await cmd.run(_ctx(out), ['mode', 'auto']);
      await cmd.run(_ctx(out), ['status']);
      expect(out.first, 'ai: mode set to auto');
      expect(out[1], contains('(mode: auto)'));
      expect(changes, [AgentMode.auto]);
      expect(cmd.usage, contains('(mode: auto)'));
    });

    for (final args in [
      ['mode'],
      ['mode', 'bogus'],
    ]) {
      test(':ai ${args.join(' ')} prints the mode usage', () async {
        final changes = <AgentMode>[];
        final out = <String>[];
        await command(onModeChanged: changes.add).run(_ctx(out), args);
        expect(out, ['ai: usage: :ai mode <standard|plan|auto>']);
        expect(changes, isEmpty);
      });
    }
  });

  group(':ai lang', () {
    test('with no value reports the current language', () async {
      final out = <String>[];
      await command().run(_ctx(out), ['lang']);
      expect(out, ['ai: language is (model default)']);
    });

    test('sets a multi-word language, then `off` resets it', () async {
      final changes = <String?>[];
      final cmd = command(onLanguageChanged: changes.add);
      final out = <String>[];
      await cmd.run(_ctx(out), ['lang', 'brazilian', 'portuguese']);
      await cmd.run(_ctx(out), ['lang']);
      await cmd.run(_ctx(out), ['language', 'off']);
      expect(out, [
        'ai: language set to brazilian portuguese',
        'ai: language is brazilian portuguese',
        'ai: language reset to the model default',
      ]);
      expect(changes, ['brazilian portuguese', null]);
    });
  });

  group(':ai <prompt>', () {
    for (final args in [
      ['--auto'],
      ['--plan', '--lang', 'es', '  '],
    ]) {
      test(':ai ${args.join(' ')} with no goal says so', () async {
        final provider = _ScriptedProvider([]);
        final out = <String>[];
        await command(provider: provider).run(_ctx(out), args);
        expect(out, ['ai: no prompt given']);
        expect(provider.calls, isEmpty);
      });
    }

    test(
      'standard mode runs an approved command in the live session',
      () async {
        final provider = _ScriptedProvider([
          _tools([_runCmd('ls -la')]),
          _say('All done'),
        ]);
        final console = _Console(['y']);
        final out = <String>[];
        await command(
          config: _config.copyWith(defaultMode: AgentMode.standard),
          provider: provider,
        ).run(_ctx(out, console: console), ['list', 'files']);

        expect(console.ran, ['ls -la']);
        expect(provider.calls.first.last.text, 'list files');
        // An unknown exit code from the session is treated as success, and the
        // captured output reaches the model.
        final result = provider.toolResultIn(1);
        expect(result.isError, isFalse);
        expect(result.content, contains('file.txt'));
        // The session already echoed the output, so it is not printed again.
        expect(out.join('\n'), isNot(contains('file.txt')));
        expect(out.join('\n'), contains('All done'));
        // Ctrl-C is wired for the run and released afterwards.
        expect(console.interruptHandlers.first, isNotNull);
        expect(console.interruptHandlers.last, isNull);
      },
    );

    test('a declined command is not run and the model is told', () async {
      final provider = _ScriptedProvider([
        _tools([_runCmd('rm -rf build')]),
        _say('ok, stopping'),
      ]);
      final console = _Console(['n']);
      await command(
        provider: provider,
      ).run(_ctx([], console: console), ['--standard', 'clean']);
      expect(console.ran, isEmpty);
      expect(provider.toolResultIn(1).content, contains('declined'));
    });

    test('`q` at a command prompt aborts the whole run', () async {
      final provider = _ScriptedProvider([
        _tools([_runCmd('rm -rf build')]),
        _say('never reached'),
      ]);
      final console = _Console(['q']);
      final out = <String>[];
      await command(
        provider: provider,
      ).run(_ctx(out, console: console), ['--standard', 'clean']);
      expect(console.ran, isEmpty);
      expect(provider.calls, hasLength(1));
      expect(out.join('\n'), isNot(contains('never reached')));
    });

    test('`?` explains the command and asks again', () async {
      final provider = _ScriptedProvider([
        _tools([_runCmd('rm -rf build')]),
        _say('Deletes the build directory.'),
        _say('Cleaned'),
      ]);
      final console = _Console(['?', 'yes']);
      final out = <String>[];
      await command(
        provider: provider,
      ).run(_ctx(out, console: console), ['--standard', 'clean']);
      expect(out.join('\n'), contains('Deletes the build directory.'));
      expect(console.ran, ['rm -rf build']);
      // The explanation is a separate, tool-less request about the command.
      expect(provider.calls[1].last.text, 'rm -rf build');
    });

    test('without a prompt reader every command is declined', () async {
      final provider = _ScriptedProvider([
        _tools([_runCmd('rm -rf build')]),
        _say('Could not run it'),
      ]);
      final console = _Console();
      await command(provider: provider).run(
        _ctx([], console: console, interactive: false),
        ['--standard', 'clean'],
      );
      expect(console.ran, isEmpty);
      expect(console.prompts, isEmpty);
      expect(provider.toolResultIn(1).content, contains('declined'));
    });

    test(
      '--auto runs without confirmation and does not change the default',
      () async {
        final provider = _ScriptedProvider([
          _tools([_runCmd('touch x')]),
          _say('Created'),
        ]);
        final console = _Console();
        final cmd = command(provider: provider);
        final out = <String>[];
        await cmd.run(_ctx(out, console: console), ['--auto', 'make', 'x']);
        expect(console.ran, ['touch x']);
        // Only the follow-up chat prompt was shown — no confirmation.
        expect(console.prompts, hasLength(1));
        expect(console.prompts.single, contains('Chat to continue'));

        out.clear();
        await cmd.run(_ctx(out), ['status']);
        expect(out.first, contains('(mode: plan)'));
      },
    );

    test(
      'without a live session commands go through the client exec',
      () async {
        final provider = _ScriptedProvider([
          _tools([_runCmd('touch x')]),
          _say('Failed'),
        ]);
        final console = _Console();
        await command(provider: provider).run(
          _ctx([], console: console, liveSession: false),
          ['--auto', 'make', 'x'],
        );
        expect(console.ran, isEmpty);
        // The test client is not connected, so the exec fails and says why.
        final result = provider.toolResultIn(1);
        expect(result.isError, isTrue);
        expect(result.content, startsWith('Execution failed:'));
      },
    );

    test(
      'keeps chatting in the same context until the reply is empty',
      () async {
        final provider = _ScriptedProvider([_say('first'), _say('second')]);
        final console = _Console(['and more?']);
        final out = <String>[];
        await command(
          provider: provider,
        ).run(_ctx(out, console: console), ['hello']);
        expect(provider.calls, hasLength(2));
        expect(provider.calls[1].last.text, 'and more?');
        expect(out.join('\n'), allOf(contains('first'), contains('second')));
      },
    );

    test('describes the node, cwd and shell syntax to the model', () async {
      final provider = _ScriptedProvider([_say('hi')]);
      await command(provider: provider).run(
        _ctx(
          [],
          console: _Console(),
          shellFamily: ShellFamily.powershell,
          cwd: '/srv/app',
        ),
        ['hi'],
      );
      expect(
        provider.systemPrompt,
        allOf(
          contains('Hostname: host'),
          contains('Shell syntax: powershell'),
          contains('Working directory: /srv/app'),
        ),
      );
    });

    test('cmd sessions use the Windows cmd syntax', () async {
      final provider = _ScriptedProvider([_say('hi')]);
      await command(provider: provider).run(
        _ctx([], console: _Console(), shellFamily: ShellFamily.cmd),
        ['hi'],
      );
      expect(provider.systemPrompt, contains('Shell syntax: windowsCmd'));
    });

    test('--lang overrides the configured language for one run', () async {
      final spanish = _ScriptedProvider([_say('hola')]);
      final cmd = command(
        config: _config.copyWith(language: 'portuguese'),
        provider: spanish,
      );
      await cmd.run(_ctx([], console: _Console()), ['--lang', 'spanish', 'hi']);
      expect(spanish.systemPrompt, contains('spanish'));
      expect(spanish.systemPrompt, isNot(contains('portuguese')));
    });

    test('--lang off drops the configured language for one run', () async {
      final provider = _ScriptedProvider([_say('hi')]);
      await command(
        config: _config.copyWith(language: 'portuguese'),
        provider: provider,
      ).run(_ctx([], console: _Console()), ['--language', 'off', 'hi']);
      expect(provider.systemPrompt, isNot(contains('portuguese')));
    });
  });

  group(':ai Ctrl-C', () {
    Future<(_ScriptedProvider, _Console, String)> interrupt(
      String answer,
    ) async {
      final provider = _ScriptedProvider([
        _tools([_runCmd('touch a')]),
        _tools([_runCmd('touch b')]),
        _say('Finished'),
      ]);
      final console = _Console([answer], true);
      final out = <String>[];
      await command(
        provider: provider,
      ).run(_ctx(out, console: console), ['--auto', 'touch', 'things']);
      return (provider, console, out.join('\n'));
    }

    test('asks to confirm, and `y` stops the run', () async {
      final (provider, console, text) = await interrupt('y');
      expect(console.prompts.first, contains('Abort the AI agent?'));
      expect(console.ran, ['touch a']);
      expect(provider.calls, hasLength(1));
      expect(text, contains('ai: aborted.'));
    });

    test('declining the abort lets the run continue', () async {
      final (provider, console, text) = await interrupt('n');
      expect(console.ran, ['touch a', 'touch b']);
      expect(provider.calls, hasLength(3));
      expect(text, contains('Finished'));
      expect(text, isNot(contains('ai: aborted.')));
    });
  });

  group(':ai plan approval', () {
    Future<(_ScriptedProvider, _Console, String)> runPlan(
      List<String> answers, {
      List<AiResult>? script,
    }) async {
      final provider = _ScriptedProvider(
        script ??
            [
              _tools([_plan]),
              _tools([_runCmd('mkdir d')]),
              _say('Done'),
            ],
      );
      final console = _Console(answers);
      final out = <String>[];
      await command(
        provider: provider,
      ).run(_ctx(out, console: console), ['make', 'a', 'dir']);
      return (provider, console, out.join('\n'));
    }

    test('[a]ll runs the plan without re-confirming each step', () async {
      final (_, console, text) = await runPlan(['a']);
      expect(text, contains('Plan: Make the dir'));
      expect(text, contains('1. mkdir d'));
      expect(text, contains('create it'));
      expect(console.ran, ['mkdir d']);
      expect(console.prompts.first, contains('Approve plan?'));
      expect(console.prompts, hasLength(2)); // approve + follow-up chat
    });

    test('[s]tep-by-step confirms each command', () async {
      final (_, console, _) = await runPlan(['step', 'y']);
      expect(console.ran, ['mkdir d']);
      expect(console.prompts, hasLength(3)); // approve + confirm + follow-up
    });

    test('[t]alk sends the notes back instead of approving', () async {
      final (provider, console, _) = await runPlan(
        ['talk', 'use /opt instead'],
        script: [
          _tools([_plan]),
          _say('Will revise'),
        ],
      );
      expect(console.prompts[1], contains('Notes for the agent'));
      expect(provider.toolResultIn(1).content, contains('use /opt instead'));
      expect(console.ran, isEmpty);
    });

    test('`q` aborts at the plan prompt', () async {
      final (provider, console, _) = await runPlan(['q']);
      expect(console.ran, isEmpty);
      expect(provider.calls, hasLength(1));
    });

    test('any other answer cancels the plan and ends the run', () async {
      final (provider, console, _) = await runPlan(['n']);
      expect(console.ran, isEmpty);
      expect(provider.calls, hasLength(1)); // no further model turns
      expect(console.prompts, hasLength(1)); // no follow-up chat either
    });
  });

  test('dispose closes the provider', () async {
    final provider = _FakeProvider();
    await command(provider: provider).dispose();
    expect(provider.closed, isTrue);
  });
}
