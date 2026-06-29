import 'dart:async';

import 'package:command_shield/command_shield.dart';
import 'package:omnyshell/src/application/ai/agent_abort.dart';
import 'package:omnyshell/src/application/ai/agent_mode.dart';
import 'package:omnyshell/src/application/ai/agent_service.dart';
import 'package:omnyshell/src/application/ai/agent_style.dart';
import 'package:omnyshell/src/application/ai/ai_config.dart';
import 'package:omnyshell/src/application/ai/command_runner.dart';
import 'package:omnyshell/src/application/ai/providers/ai_provider.dart';
import 'package:test/test.dart';

/// A provider that replays a fixed script of [AiResult]s, one per `chat` call,
/// and records the messages it was given.
class ScriptedProvider implements AiProvider {
  ScriptedProvider(this._script);

  final List<AiResult> _script;
  int _i = 0;
  final List<List<AiMessage>> calls = [];

  /// The model passed to each `chat` call, in order.
  final List<String?> models = [];

  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) async {
    calls.add(List.of(messages));
    models.add(model);
    return _script[_i++];
  }

  @override
  void close() {}
}

/// A provider whose `chat` never completes — used to test that an abort during
/// a slow model call is responsive (the pending request is abandoned).
class _BlockingProvider implements AiProvider {
  bool started = false;
  bool completed = false;

  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) {
    started = true;
    return Completer<AiResult>().future.then((r) {
      completed = true;
      return r;
    });
  }

  @override
  void close() {}
}

class FakeRunner implements AgentCommandRunner {
  FakeRunner({this.failOn = const {}, this.echoesToTerminal = false});

  /// Commands that should exit non-zero.
  final Set<String> failOn;
  @override
  final bool echoesToTerminal;
  final List<String> ran = [];

  @override
  Future<CommandRun> run(String command) async {
    ran.add(command);
    final fail = failOn.contains(command);
    return CommandRun(
      exitCode: fail ? 1 : 0,
      stdout: fail ? '' : 'ok',
      stderr: fail ? 'boom' : '',
    );
  }
}

AiToolCall _runCmd(String id, String command) =>
    AiToolCall(id: id, name: 'run_command', arguments: {'command': command});

AgentService _service({
  required AiProvider provider,
  required AgentCommandRunner runner,
  required Future<bool> Function(String) confirm,
  Future<PlanApproval> Function(AgentPlan)? approvePlan,
  Future<String> Function()? planNotes,
  AiConfig config = const AiConfig(
    provider: AiProviderKind.anthropic,
    model: 'test',
    apiKey: 'k',
  ),
  AgentStyle style = const AgentStyle(),
  String? language,
  List<String>? out,
}) => AgentService(
  provider: provider,
  runner: runner,
  shield: CommandShield(),
  config: config,
  style: style,
  language: language,
  syntax: CommandSyntax.bash,
  environment: const AgentEnvironment(os: 'linux', arch: 'x64', hostname: 'h'),
  handlers: AgentHandlers(
    writeLine: (l) => out?.add(l),
    confirm: confirm,
    approvePlan: approvePlan ?? (_) async => PlanApproval.cancel,
    planNotes: planNotes,
  ),
);

void main() {
  group('command_shield auto-block', () {
    test(
      'blocks deny/critical commands in every mode and never runs them',
      () async {
        for (final mode in AgentMode.values) {
          final runner = FakeRunner();
          final provider = ScriptedProvider([
            AiResult(
              toolCalls: [_runCmd('1', 'rm -rf /')],
              stopReason: AiStopReason.toolUse,
            ),
            const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
          ]);
          final out = <String>[];
          final svc = _service(
            provider: provider,
            runner: runner,
            confirm: (_) async => true, // would allow if asked
            approvePlan: (_) async => PlanApproval.all,
            out: out,
          );

          await svc.run('clean up', mode: mode);

          expect(
            runner.ran,
            isEmpty,
            reason: 'mode $mode must not run rm -rf /',
          );
          expect(out.any((l) => l.contains('blocked')), isTrue);
        }
      },
    );

    test('allows a safe command to run', () async {
      final runner = FakeRunner();
      final provider = ScriptedProvider([
        AiResult(
          toolCalls: [_runCmd('1', 'git status')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final svc = _service(
        provider: provider,
        runner: runner,
        confirm: (_) async => true,
      );

      await svc.run('check repo', mode: AgentMode.auto);

      expect(runner.ran, ['git status']);
    });
  });

  group('mode confirmation contract', () {
    test('standard confirms each command before running', () async {
      final runner = FakeRunner();
      final provider = ScriptedProvider([
        AiResult(
          toolCalls: [_runCmd('1', 'apt-get install -y docker')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      var confirmCalls = 0;
      final svc = _service(
        provider: provider,
        runner: runner,
        confirm: (_) async {
          confirmCalls++;
          return false; // user declines
        },
      );

      await svc.run('install docker', mode: AgentMode.standard);

      expect(confirmCalls, 1);
      expect(runner.ran, isEmpty, reason: 'declined command must not run');
    });

    test('auto runs an allow-level command without confirmation', () async {
      final runner = FakeRunner();
      final provider = ScriptedProvider([
        AiResult(
          toolCalls: [_runCmd('1', 'uname -a')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      var confirmCalls = 0;
      final svc = _service(
        provider: provider,
        runner: runner,
        confirm: (_) async {
          confirmCalls++;
          return true;
        },
      );

      await svc.run('inspect', mode: AgentMode.auto);

      expect(confirmCalls, 0);
      expect(runner.ran, ['uname -a']);
    });

    test(
      'plan presents a plan, then runs approved steps without re-confirm',
      () async {
        final runner = FakeRunner();
        final provider = ScriptedProvider([
          // 1) model presents a plan
          AiResult(
            toolCalls: [
              const AiToolCall(
                id: 'p1',
                name: 'present_plan',
                arguments: {
                  'summary': 'install docker',
                  'steps': [
                    {'command': 'apt-get update'},
                    {'command': 'apt-get install -y docker.io'},
                  ],
                },
              ),
            ],
            stopReason: AiStopReason.toolUse,
          ),
          // 2) model executes step one
          AiResult(
            toolCalls: [_runCmd('1', 'apt-get update')],
            stopReason: AiStopReason.toolUse,
          ),
          // 3) and step two
          AiResult(
            toolCalls: [_runCmd('2', 'apt-get install -y docker.io')],
            stopReason: AiStopReason.toolUse,
          ),
          const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
        ]);

        var planShown = false;
        var confirmCalls = 0;
        final svc = _service(
          provider: provider,
          runner: runner,
          confirm: (_) async {
            confirmCalls++;
            return true;
          },
          approvePlan: (plan) async {
            planShown = true;
            expect(plan.steps, hasLength(2));
            return PlanApproval.all;
          },
        );

        await svc.run('install docker', mode: AgentMode.plan);

        expect(planShown, isTrue);
        expect(confirmCalls, 0, reason: 'approve-all skips per-step confirm');
        expect(runner.ran, ['apt-get update', 'apt-get install -y docker.io']);
      },
    );

    test('plan cancellation stops the agent', () async {
      final runner = FakeRunner();
      final provider = ScriptedProvider([
        AiResult(
          toolCalls: [
            const AiToolCall(
              id: 'p1',
              name: 'present_plan',
              arguments: {
                'steps': [
                  {'command': 'rm -rf /var/log'},
                ],
              },
            ),
          ],
          stopReason: AiStopReason.toolUse,
        ),
      ]);
      final svc = _service(
        provider: provider,
        runner: runner,
        confirm: (_) async => true,
        approvePlan: (_) async => PlanApproval.cancel,
      );

      final result = await svc.run('purge logs', mode: AgentMode.plan);

      expect(result, isNull);
      expect(runner.ran, isEmpty);
      expect(provider.calls, hasLength(1), reason: 'loop stops after cancel');
    });
  });

  group('per-phase model selection', () {
    const split = AiConfig(
      provider: AiProviderKind.anthropic,
      model: 'shared',
      apiKey: 'k',
      plannerModel: 'PLANNER',
      executorModel: 'EXECUTOR',
    );

    test('investigation uses planner; turn after a mutating command uses '
        'executor; read-only keeps planner', () async {
      final provider = ScriptedProvider([
        // turn 0: read-only probe (investigation)
        AiResult(
          toolCalls: [_runCmd('1', 'cat /etc/os-release')],
          stopReason: AiStopReason.toolUse,
        ),
        // turn 1: still read-only → planner
        AiResult(
          toolCalls: [_runCmd('2', 'which docker')],
          stopReason: AiStopReason.toolUse,
        ),
        // turn 2: a mutating command
        AiResult(
          toolCalls: [_runCmd('3', 'apt-get install -y docker.io')],
          stopReason: AiStopReason.toolUse,
        ),
        // turn 3: processes the mutation result → executor
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final svc = _service(
        provider: provider,
        runner: FakeRunner(),
        confirm: (_) async => true,
        config: split,
      );

      await svc.run('install docker', mode: AgentMode.auto);

      expect(provider.models, ['PLANNER', 'PLANNER', 'PLANNER', 'EXECUTOR']);
    });

    test('plan mode uses executor once the plan is approved', () async {
      final provider = ScriptedProvider([
        // turn 0 (planning): present the plan
        AiResult(
          toolCalls: [
            const AiToolCall(
              id: 'p1',
              name: 'present_plan',
              arguments: {
                'steps': [
                  {'command': 'apt-get install -y docker.io'},
                ],
              },
            ),
          ],
          stopReason: AiStopReason.toolUse,
        ),
        // turn 1 (executing, plan approved): run the step
        AiResult(
          toolCalls: [_runCmd('1', 'apt-get install -y docker.io')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final svc = _service(
        provider: provider,
        runner: FakeRunner(),
        confirm: (_) async => true,
        approvePlan: (_) async => PlanApproval.all,
        config: split,
      );

      await svc.run('install docker', mode: AgentMode.plan);

      expect(provider.models, ['PLANNER', 'EXECUTOR', 'EXECUTOR']);
    });

    test('a single shared model is used for every phase', () async {
      final provider = ScriptedProvider([
        AiResult(
          toolCalls: [_runCmd('1', 'apt-get install -y docker.io')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final svc = _service(
        provider: provider,
        runner: FakeRunner(),
        confirm: (_) async => true,
        // default config: only `model: 'test'`, no planner/executor
      );

      await svc.run('install docker', mode: AgentMode.auto);

      expect(provider.models, ['test', 'test']);
    });
  });

  group('replan on failure (plan mode)', () {
    test('a failed approved step forces the next mutating command to '
        're-confirm', () async {
      final runner = FakeRunner(failOn: {'touch /opt/a'});
      final provider = ScriptedProvider([
        // present plan, approved "all"
        AiResult(
          toolCalls: [
            const AiToolCall(
              id: 'p1',
              name: 'present_plan',
              arguments: {
                'steps': [
                  {'command': 'touch /opt/a'},
                  {'command': 'mkdir /opt/b'},
                ],
              },
            ),
          ],
          stopReason: AiStopReason.toolUse,
        ),
        // step-a runs (no confirm) and FAILS
        AiResult(
          toolCalls: [_runCmd('1', 'touch /opt/a')],
          stopReason: AiStopReason.toolUse,
        ),
        // model ignores the advice and tries step-b anyway → must be confirmed
        AiResult(
          toolCalls: [_runCmd('2', 'mkdir /opt/b')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      var confirmCalls = 0;
      final svc = _service(
        provider: provider,
        runner: runner,
        confirm: (_) async {
          confirmCalls++;
          return true;
        },
        approvePlan: (_) async => PlanApproval.all,
      );

      await svc.run('do it', mode: AgentMode.plan);

      // step-a auto-ran (approved), step-b required a fresh confirmation.
      expect(runner.ran, ['touch /opt/a', 'mkdir /opt/b']);
      expect(
        confirmCalls,
        1,
        reason: 'mutating step after a failure re-confirms',
      );
    });

    test(
      're-presenting a plan after a failure clears the re-confirm gate',
      () async {
        final runner = FakeRunner(failOn: {'touch /opt/a'});
        final provider = ScriptedProvider([
          AiResult(
            toolCalls: [
              const AiToolCall(
                id: 'p1',
                name: 'present_plan',
                arguments: {
                  'steps': [
                    {'command': 'touch /opt/a'},
                  ],
                },
              ),
            ],
            stopReason: AiStopReason.toolUse,
          ),
          // step-a fails
          AiResult(
            toolCalls: [_runCmd('1', 'touch /opt/a')],
            stopReason: AiStopReason.toolUse,
          ),
          // agent adjusts and re-presents → re-approved
          AiResult(
            toolCalls: [
              const AiToolCall(
                id: 'p2',
                name: 'present_plan',
                arguments: {
                  'steps': [
                    {'command': 'mkdir /opt/b'},
                  ],
                },
              ),
            ],
            stopReason: AiStopReason.toolUse,
          ),
          // step-a2 runs under the fresh approval → no per-command confirm
          AiResult(
            toolCalls: [_runCmd('2', 'mkdir /opt/b')],
            stopReason: AiStopReason.toolUse,
          ),
          const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
        ]);
        var confirmCalls = 0;
        var approvals = 0;
        final svc = _service(
          provider: provider,
          runner: runner,
          confirm: (_) async {
            confirmCalls++;
            return true;
          },
          approvePlan: (_) async {
            approvals++;
            return PlanApproval.all;
          },
        );

        await svc.run('do it', mode: AgentMode.plan);

        expect(approvals, 2, reason: 'plan re-presented and re-approved');
        expect(runner.ran, ['touch /opt/a', 'mkdir /opt/b']);
        expect(confirmCalls, 0, reason: 'fresh approval resumes auto-run');
      },
    );
  });

  group('echoesToTerminal runner (live session)', () {
    test('does not re-print captured output but still feeds it to the model and '
        'flips replan on failure', () async {
      final runner = FakeRunner(
        failOn: {'apt-get update'},
        echoesToTerminal: true,
      );
      final provider = ScriptedProvider([
        AiResult(
          toolCalls: [_runCmd('1', 'apt-get update')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final out = <String>[];
      final svc = _service(
        provider: provider,
        runner: runner,
        confirm: (_) async => true,
        out: out,
        approvePlan: (_) async => PlanApproval.all,
      );

      // plan mode so the failure → replan notice path is exercised
      await svc.run('update', mode: AgentMode.plan);

      // command header is still shown, but the captured stdout/stderr ('boom')
      // is NOT re-printed (the live shell already showed it).
      expect(out.any((l) => l.contains(r'$ apt-get update')), isTrue);
      expect(out.any((l) => l.contains('boom')), isFalse);
      // the model still received the output + exit code (tool result), and the
      // failure was surfaced as a notice.
      expect(out.any((l) => l.contains('command failed')), isTrue);

      // the tool result fed to the model includes the captured stderr.
      final toolMsgs = provider.calls.last
          .where((m) => m.role == AiRole.tool)
          .map((m) => m.toolResult!.content)
          .join('\n');
      expect(toolMsgs, contains('boom'));
    });
  });

  group('explain command (?) at confirm', () {
    test('explain triggers a model call, prints it, and re-prompts', () async {
      final runner = FakeRunner();
      // chat 1: ask to run a command; chat 2 (no tools): the explanation;
      // chat 3: final summary.
      final provider = ScriptedProvider([
        AiResult(
          toolCalls: [_runCmd('1', 'rm -rf build')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(
          text: 'Deletes the build directory recursively.',
          stopReason: AiStopReason.endTurn,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final out = <String>[];
      var asks = 0;
      final svc = AgentService(
        provider: provider,
        runner: runner,
        shield: CommandShield(),
        config: const AiConfig(
          provider: AiProviderKind.anthropic,
          model: 'm',
          apiKey: 'k',
        ),
        syntax: CommandSyntax.bash,
        environment: const AgentEnvironment(
          os: 'linux',
          arch: 'x64',
          hostname: 'h',
        ),
        handlers: AgentHandlers(
          writeLine: out.add,
          confirm: (_) async => true,
          approvePlan: (_) async => PlanApproval.cancel,
          // first answer: explain; second: yes
          confirmCommand: (_) async {
            asks++;
            return asks == 1 ? CommandConfirm.explain : CommandConfirm.yes;
          },
        ),
      );

      await svc.run('clean', mode: AgentMode.standard);

      expect(asks, 2, reason: 're-prompted after explaining');
      expect(provider.calls, hasLength(3), reason: 'one extra call to explain');
      expect(out.any((l) => l.contains('Deletes the build directory')), isTrue);
      expect(runner.ran, ['rm -rf build']);
    });

    test('without confirmCommand it falls back to plain yes/no', () async {
      final runner = FakeRunner();
      final provider = ScriptedProvider([
        AiResult(
          toolCalls: [_runCmd('1', 'ls')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      var confirms = 0;
      final svc = _service(
        provider: provider,
        runner: runner,
        confirm: (_) async {
          confirms++;
          return true;
        }, // no confirmCommand passed
      );

      await svc.run('list', mode: AgentMode.standard);

      expect(confirms, 1);
      expect(runner.ran, ['ls']);
    });
  });

  group('talk (plan notes)', () {
    test(
      'feeds the user notes back and the agent re-presents the plan',
      () async {
        AiToolCall plan(String id, String cmd) => AiToolCall(
          id: id,
          name: 'present_plan',
          arguments: {
            'steps': [
              {'command': cmd},
            ],
          },
        );
        final runner = FakeRunner();
        final provider = ScriptedProvider([
          AiResult(
            toolCalls: [plan('p1', 'touch /opt/a')],
            stopReason: AiStopReason.toolUse,
          ),
          // after talk, the agent revises and re-presents
          AiResult(
            toolCalls: [plan('p2', 'mkdir /opt/b')],
            stopReason: AiStopReason.toolUse,
          ),
          AiResult(
            toolCalls: [_runCmd('1', 'mkdir /opt/b')],
            stopReason: AiStopReason.toolUse,
          ),
          const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
        ]);
        var approvals = 0;
        final svc = _service(
          provider: provider,
          runner: runner,
          confirm: (_) async => true,
          approvePlan: (_) async {
            approvals++;
            return approvals == 1 ? PlanApproval.talk : PlanApproval.all;
          },
          planNotes: () async => 'use mkdir instead of touch',
        );

        await svc.run('set up', mode: AgentMode.plan);

        expect(approvals, 2, reason: 'talk then approve');
        // the notes reached the model as a tool result before the re-presented plan
        final toolText = provider.calls.last
            .where((m) => m.role == AiRole.tool)
            .map((m) => m.toolResult!.content)
            .join('\n');
        expect(toolText, contains('use mkdir instead of touch'));
        expect(runner.ran, ['mkdir /opt/b']);
      },
    );
  });

  group('reply language', () {
    String systemPromptOf(ScriptedProvider p) =>
        p.calls.first.firstWhere((m) => m.role == AiRole.system).text!;

    test('pins the configured language in the system prompt', () async {
      final provider = ScriptedProvider([
        const AiResult(text: 'pronto', stopReason: AiStopReason.endTurn),
      ]);
      final svc = _service(
        provider: provider,
        runner: FakeRunner(),
        confirm: (_) async => true,
        language: 'portuguese',
      );

      await svc.run('x', mode: AgentMode.auto);

      expect(systemPromptOf(provider), contains('in portuguese'));
    });

    test('no language → no language rule', () async {
      final provider = ScriptedProvider([
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final svc = _service(
        provider: provider,
        runner: FakeRunner(),
        confirm: (_) async => true,
      );

      await svc.run('x', mode: AgentMode.auto);

      expect(
        systemPromptOf(provider).toLowerCase(),
        isNot(contains('write every user-facing message')),
      );
    });
  });

  group('interaction framing', () {
    test(
      'frames the run with a cyan rule and a blank line before the summary',
      () async {
        final esc = String.fromCharCode(0x1b);
        final provider = ScriptedProvider([
          AiResult(
            toolCalls: [_runCmd('1', 'uname -a')],
            stopReason: AiStopReason.toolUse,
          ),
          const AiResult(text: 'all set', stopReason: AiStopReason.endTurn),
        ]);
        final out = <String>[];
        final svc = AgentService(
          provider: provider,
          runner: FakeRunner(),
          shield: CommandShield(),
          config: const AiConfig(
            provider: AiProviderKind.anthropic,
            model: 'm',
            apiKey: 'k',
          ),
          style: const AnsiAgentStyle(),
          syntax: CommandSyntax.bash,
          environment: const AgentEnvironment(
            os: 'linux',
            arch: 'x64',
            hostname: 'h',
          ),
          handlers: AgentHandlers(
            writeLine: out.add,
            confirm: (_) async => true,
            approvePlan: (_) async => PlanApproval.all,
            rule: () => '----', // host-sized rule (cyan applied by the agent)
          ),
        );

        final result = await svc.run('check', mode: AgentMode.auto);

        expect(result, 'all set');
        // opens and closes with a cyan rule
        final ruleLine = '$esc[36m----$esc[0m';
        expect(out.first, ruleLine, reason: 'starts with a cyan rule');
        expect(out.last, ruleLine, reason: 'ends with a cyan rule');
        // a blank line precedes the final summary, which precedes the closing rule
        final blank = out.lastIndexOf('');
        final summary = out.indexWhere((l) => l.contains('all set'));
        expect(
          blank + 1,
          summary,
          reason: 'blank line immediately before summary',
        );
        expect(summary < out.length - 1, isTrue);
      },
    );

    test('omits the rule when the host provides none', () async {
      final provider = ScriptedProvider([
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final out = <String>[];
      final svc = _service(
        provider: provider,
        runner: FakeRunner(),
        confirm: (_) async => true,
        out: out, // _service builds handlers without `rule`
      );

      await svc.run('x', mode: AgentMode.auto);

      // no rule glyphs; still has the blank line + summary
      expect(out.any((l) => l.contains('─')), isFalse);
      expect(out, contains(''));
      expect(out, contains('done'));
    });
  });

  group('abort', () {
    test(
      'an explicit (confirmed) abort at a prompt stops without running',
      () async {
        final cancel = AgentAbort();
        final runner = FakeRunner();
        final provider = ScriptedProvider([
          AiResult(
            toolCalls: [_runCmd('1', 'apt-get install -y docker.io')],
            stopReason: AiStopReason.toolUse,
          ),
          const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
        ]);
        final out = <String>[];
        final svc = _service(
          provider: provider,
          runner: runner,
          // emulate an `abort` answer at the Run? prompt
          confirm: (_) async {
            cancel.requestConfirmed();
            return false;
          },
          out: out,
        );

        final result = await svc.run(
          'install',
          mode: AgentMode.standard,
          abort: cancel,
        );

        expect(result, isNull);
        expect(runner.ran, isEmpty);
        expect(out.any((l) => l.contains('ai: aborted.')), isTrue);
      },
    );

    test(
      'Ctrl-C request + confirm yes stops before the next model call',
      () async {
        final cancel = AgentAbort()..request(); // unconfirmed (Ctrl-C)
        final provider = ScriptedProvider([
          const AiResult(text: 'unused', stopReason: AiStopReason.endTurn),
        ]);
        final out = <String>[];
        final svc = _service(
          provider: provider,
          runner: FakeRunner(),
          confirm: (p) async => true, // answer "y" to "Abort the AI agent?"
          out: out,
        );

        final result = await svc.run('do', mode: AgentMode.auto, abort: cancel);

        expect(result, isNull);
        expect(
          provider.calls,
          isEmpty,
          reason: 'aborted before the first chat',
        );
        expect(out.any((l) => l.contains('ai: aborted.')), isTrue);
      },
    );

    test(
      'Ctrl-C request + confirm no clears the abort and continues',
      () async {
        final cancel = AgentAbort()..request();
        final runner = FakeRunner();
        final provider = ScriptedProvider([
          AiResult(
            toolCalls: [_runCmd('1', 'uname -a')],
            stopReason: AiStopReason.toolUse,
          ),
          const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
        ]);
        final out = <String>[];
        final svc = _service(
          provider: provider,
          runner: runner,
          confirm: (p) async => false, // decline the abort
          out: out,
        );

        final result = await svc.run(
          'inspect',
          mode: AgentMode.auto,
          abort: cancel,
        );

        expect(result, 'done');
        expect(runner.ran, ['uname -a']);
        expect(out.any((l) => l.contains('ai: aborted.')), isFalse);
      },
    );

    test('an abort during a slow model call is responsive (race)', () async {
      final cancel = AgentAbort();
      final provider = _BlockingProvider();
      final out = <String>[];
      final svc = _service(
        provider: provider,
        runner: FakeRunner(),
        confirm: (p) async => true,
        out: out,
      );

      final fut = svc.run('do', mode: AgentMode.auto, abort: cancel);
      await Future<void>.delayed(Duration.zero); // reach the chat race
      expect(provider.started, isTrue);
      cancel.request(); // Ctrl-C while the model call is pending
      final result = await fut;

      expect(result, isNull);
      expect(provider.completed, isFalse, reason: 'pending request abandoned');
      expect(out.any((l) => l.contains('ai: aborted.')), isTrue);
    });
  });

  group('output styling', () {
    final esc = String.fromCharCode(0x1b);

    test(
      'colors assistant prose, command echo, plan and prompt by category',
      () async {
        final provider = ScriptedProvider([
          // planning turn presents a plan
          AiResult(
            text: 'investigating',
            toolCalls: [
              const AiToolCall(
                id: 'p1',
                name: 'present_plan',
                arguments: {
                  'steps': [
                    {'command': 'apt-get install -y docker.io'},
                  ],
                },
              ),
            ],
            stopReason: AiStopReason.toolUse,
          ),
          // executing the approved step
          AiResult(
            toolCalls: [_runCmd('1', 'apt-get install -y docker.io')],
            stopReason: AiStopReason.toolUse,
          ),
          const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
        ]);
        final out = <String>[];
        final svc = _service(
          provider: provider,
          runner: FakeRunner(),
          confirm: (_) async => true,
          approvePlan: (_) async => PlanApproval.all,
          style: const AnsiAgentStyle(),
          out: out,
        );

        await svc.run('install docker', mode: AgentMode.plan);

        // planning prose → cyan (36)
        expect(out, contains('$esc[36minvestigating$esc[0m'));
        // plan lines → cyan
        expect(out.any((l) => l.startsWith('$esc[36m  1. ')), isTrue);
        // executing command echo → green (32)
        expect(out, contains('$esc[32m\$ apt-get install -y docker.io$esc[0m'));
      },
    );

    test(
      'Run: header is printed separately; the prompt is single-line options',
      () async {
        final provider = ScriptedProvider([
          AiResult(
            toolCalls: [_runCmd('1', 'apt-get install -y docker.io')],
            stopReason: AiStopReason.toolUse,
          ),
          const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
        ]);
        final out = <String>[];
        String? seenPrompt;
        final svc = _service(
          provider: provider,
          runner: FakeRunner(),
          confirm: (p) async {
            seenPrompt = p;
            return true;
          },
          style: const AnsiAgentStyle(),
          out: out,
        );

        await svc.run('install docker', mode: AgentMode.standard);

        // "Run: <cmd>" is an output line: magenta "Run:" + the proposed command
        // in yellow (33) — distinct from an executing command (green).
        expect(
          out,
          contains(
            '$esc[35mRun:$esc[0m $esc[33mapt-get install -y docker.io$esc[0m',
          ),
        );
        // The prompt is a single line (no newline) with the options in magenta.
        expect(seenPrompt, isNot(contains('\n')));
        expect(seenPrompt, '$esc[35m[y/N]  q=abort  ?=explain: $esc[0m');
      },
    );

    test('default no-op style leaves text unchanged', () async {
      final provider = ScriptedProvider([
        AiResult(
          text: 'plain',
          toolCalls: [_runCmd('1', 'ls')],
          stopReason: AiStopReason.toolUse,
        ),
        const AiResult(text: 'done', stopReason: AiStopReason.endTurn),
      ]);
      final out = <String>[];
      final svc = _service(
        provider: provider,
        runner: FakeRunner(),
        confirm: (_) async => true,
        out: out,
      );

      await svc.run('list', mode: AgentMode.auto);

      expect(out, contains('plain'));
      expect(out.any((l) => l.contains(esc)), isFalse);
    });
  });

  group('parsing helpers', () {
    test('AgentMode.tryParse', () {
      expect(AgentMode.tryParse('plan'), AgentMode.plan);
      expect(AgentMode.tryParse('AUTO '), isNull); // case/space sensitive
      expect(AgentMode.tryParse('auto'), AgentMode.auto);
      expect(AgentMode.tryParse('nope'), isNull);
    });

    test('AiProviderKind.tryParse', () {
      expect(AiProviderKind.tryParse('anthropic'), AiProviderKind.anthropic);
      expect(AiProviderKind.tryParse('openai'), AiProviderKind.openai);
      expect(AiProviderKind.tryParse('gemini'), AiProviderKind.gemini);
      expect(AiProviderKind.tryParse('xai'), isNull);
    });
  });
}
