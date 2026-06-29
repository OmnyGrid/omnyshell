import 'package:command_shield/command_shield.dart';

import 'agent_abort.dart';
import 'agent_mode.dart';
import 'agent_style.dart';
import 'ai_config.dart';
import 'command_runner.dart';
import 'providers/ai_provider.dart';

/// Facts about the target node, woven into the system prompt so the model knows
/// what it is operating.
class AgentEnvironment {
  const AgentEnvironment({
    required this.os,
    required this.arch,
    required this.hostname,
    this.cwd,
  });

  final String os;
  final String arch;
  final String hostname;

  /// The current remote working directory, if known.
  final String? cwd;
}

/// A single step in a proposed plan.
class AgentPlanStep {
  const AgentPlanStep({required this.command, this.explanation});

  final String command;
  final String? explanation;
}

/// A plan the model presents (in [AgentMode.plan]) before executing.
class AgentPlan {
  const AgentPlan({this.summary, required this.steps});

  final String? summary;
  final List<AgentPlanStep> steps;
}

/// The user's answer at a command-confirmation prompt.
enum CommandConfirm {
  /// Run the command.
  yes,

  /// Skip the command.
  no,

  /// Ask the agent to explain the command, then re-prompt.
  explain,
}

/// The user's verdict on a presented plan.
enum PlanApproval {
  /// Run every step without further per-step confirmation.
  all,

  /// Confirm each step individually before it runs.
  stepByStep,

  /// Send notes back to the agent so it revises the plan and re-presents it.
  talk,

  /// Abandon the plan; the agent stops.
  cancel,
}

/// Host-side interaction hooks the agent uses to talk to the user. The CLI and
/// the web client provide their own implementations; tests provide fakes.
class AgentHandlers {
  const AgentHandlers({
    required this.writeLine,
    required this.confirm,
    required this.approvePlan,
    this.confirmCommand,
    this.planNotes,
    this.rule,
    this.continueChat,
  });

  /// Writes a line of output (assistant prose, command echoes, notices).
  final void Function(String line) writeLine;

  /// Asks a yes/no question, returning the user's answer.
  final Future<bool> Function(String prompt) confirm;

  /// Asks the user to confirm a command, allowing an "explain" answer. When
  /// `null`, command confirmation falls back to [confirm] (no explain option).
  final Future<CommandConfirm> Function(String prompt)? confirmCommand;

  /// Presents [plan] and returns the user's [PlanApproval].
  final Future<PlanApproval> Function(AgentPlan plan) approvePlan;

  /// Reads the user's free-text notes when they choose [PlanApproval.talk], so
  /// the agent can revise the plan. `null` (or empty) provides no guidance.
  final Future<String> Function()? planNotes;

  /// Returns the (uncolored) horizontal-rule string used to frame the start and
  /// end of the interaction — the host sizes it to the terminal. `null` omits
  /// the rule (e.g. tests, or a host that doesn't want framing).
  final String Function()? rule;

  /// Asks the user, after the agent's final answer, for a follow-up message to
  /// continue the conversation in the same context. Returns the message, or
  /// `null`/empty to end the agent. A `null` handler ends without prompting
  /// (non-interactive hosts, web, tests).
  final Future<String?> Function()? continueChat;
}

/// Drives a provider-agnostic agent loop that investigates a node, plans and
/// executes commands to accomplish a natural-language goal.
///
/// Every command the model wants to run is first scored by [shield]; DENY or
/// `SecurityLevel.critical` commands are auto-blocked in **all** modes and never
/// run. The remaining confirmation behaviour depends on the [AgentMode] (see
/// [AgentMode] for the contract).
///
/// Pure Dart with no `dart:io`: the transport is injected via [AgentCommandRunner]
/// and all user interaction via [AgentHandlers], so the loop runs unchanged in
/// the CLI and the browser.
class AgentService {
  AgentService({
    required this.provider,
    required this.runner,
    required this.shield,
    required this.config,
    required this.syntax,
    required this.environment,
    required this.handlers,
    this.style = const AgentStyle(),
    this.language,
  });

  final AiProvider provider;
  final AgentCommandRunner runner;
  final CommandShield shield;
  final AiConfig config;

  /// The language the agent replies in (free-form), or `null` to let the model
  /// choose. Applied to its prose, plans, explanations and summaries — not to
  /// shell commands or command output.
  final String? language;

  /// The command syntax used by [shield] (derived from the node's shell family).
  final CommandSyntax syntax;

  final AgentEnvironment environment;
  final AgentHandlers handlers;

  /// Styles output by category (planning/executing/command/prompt/blocked).
  /// Defaults to a no-op; the native CLI injects an ANSI style.
  final AgentStyle style;

  /// Whether the most recently executed command mutated state. Drives the
  /// per-turn planner→executor model switch. Reset at the start of each [run].
  bool _lastCommandMutated = false;

  /// Set when a command fails or returns an unexpected result, so an approved
  /// plan must be re-presented and re-confirmed before further mutating
  /// commands run. Cleared when a (new) plan is approved. Reset per [run].
  bool _replanNeeded = false;

  /// Whether the one-time "switching to executor model" notice has fired.
  bool _announcedExecutor = false;

  /// Caps the command output fed back to the model so a chatty command cannot
  /// blow the context window.
  static const int _maxToolOutputChars = 8000;

  /// The tools exposed to the model.
  static final List<AiToolSpec> _tools = [
    const AiToolSpec(
      name: 'run_command',
      description:
          'Run a single shell command on the node and return its stdout, '
          'stderr and exit code. Use it both to investigate the node '
          '(read-only probes) and to perform changes. Run exactly one command '
          'per call; do not chain unrelated commands. Prefer non-interactive '
          'flags (e.g. -y) because no TTY is attached.',
      parameters: {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'The exact command line to execute.',
          },
          'explanation': {
            'type': 'string',
            'description':
                'A short, user-facing reason for running this command.',
          },
        },
        'required': ['command'],
      },
    ),
    const AiToolSpec(
      name: 'present_plan',
      description:
          'Present an ordered, multi-step plan for the user to approve before '
          'making any changes. Required in plan mode after investigation and '
          'before running mutating commands.',
      parameters: {
        'type': 'object',
        'properties': {
          'summary': {
            'type': 'string',
            'description': 'A one-line summary of what the plan accomplishes.',
          },
          'steps': {
            'type': 'array',
            'description': 'The ordered steps to execute.',
            'items': {
              'type': 'object',
              'properties': {
                'command': {
                  'type': 'string',
                  'description': 'The command for this step.',
                },
                'explanation': {
                  'type': 'string',
                  'description': 'What this step does and why.',
                },
              },
              'required': ['command'],
            },
          },
        },
        'required': ['steps'],
      },
    ),
  ];

  /// Runs the agent toward [goal] under [mode]. Returns the model's final
  /// summary text (also already written via [AgentHandlers.writeLine]), or
  /// `null` if the agent was aborted/cancelled or hit the step cap without
  /// concluding.
  ///
  /// [abort] lets the host stop the run (Ctrl-C or an `abort` answer at a
  /// prompt); the loop checks it at each safe point and bails out of a pending
  /// model call, confirming first unless [AgentAbort.isConfirmed].
  Future<String?> run(
    String goal, {
    required AgentMode mode,
    AgentAbort? abort,
  }) async {
    final cancel = abort ?? AgentAbort();
    final messages = <AiMessage>[
      AiMessage.system(_systemPrompt(mode)),
      AiMessage.user(goal),
    ];

    // In plan mode, tracks the approval verdict once a plan is accepted.
    PlanApproval? planApproval;

    _lastCommandMutated = false;
    _replanNeeded = false;
    _announcedExecutor = false;

    _frame(); // a horizontal rule opening the interaction

    final aborted = style.blocked('ai: aborted.');

    for (var step = 0; step < config.maxSteps; step++) {
      if (await _aborted(cancel)) return _finish(aborted);

      final phase = _phaseFor(mode: mode, planApproval: planApproval);
      final model = config.modelFor(phase);
      _maybeAnnounceExecutor(phase);

      final AiResult result;
      try {
        // Race the model call against an abort so Ctrl-C during a slow request
        // is responsive; the request itself is abandoned (its result ignored).
        final chat = provider.chat(
          messages: messages,
          tools: _tools,
          model: model,
        );
        final won = await Future.any<bool>([
          chat.then((_) => true),
          cancel.whenRequested.then((_) => false),
        ]);
        if (!won) {
          if (await _aborted(cancel)) return _finish(aborted);
        }
        result = await chat; // resolved (won) or user declined the abort
      } on AiProviderException catch (e) {
        return _finish('ai: provider error: ${e.message}');
      }

      final text = result.text?.trim();
      messages.add(
        AiMessage.assistant(text: result.text, toolCalls: result.toolCalls),
      );

      final styledText = (text == null || text.isEmpty)
          ? null
          : (phase == AgentPhase.executing
                ? style.executing(text)
                : style.planning(text));

      if (!result.wantsTools) {
        // Final answer for this turn: a blank line then the styled summary
        // (same framing as _finish). Then offer to keep chatting in the same
        // context before closing the interaction.
        handlers.writeLine('');
        if (styledText != null) handlers.writeLine(styledText);
        final followUp = await _promptContinue();
        if (followUp == null) {
          _frame(); // closing rule
          return text;
        }
        // Continue in the same context: append the user turn, reset the
        // in-flight plan state so a new sub-goal re-investigates/re-plans, and
        // give it a fresh step budget.
        messages.add(AiMessage.user(followUp));
        planApproval = null;
        _lastCommandMutated = false;
        _replanNeeded = false;
        step = -1; // the for-loop ++ makes the next iteration step 0
        continue;
      }

      if (styledText != null) handlers.writeLine(styledText);

      var cancelled = false;
      for (final call in result.toolCalls) {
        final outcome = await _handleToolCall(
          call,
          mode: mode,
          planApproval: planApproval,
          onPlanApproval: (a) => planApproval = a,
        );
        messages.add(AiMessage.tool(outcome.result));
        if (outcome.cancelled) cancelled = true;
      }
      if (cancelled) return _finish(null);
      if (await _aborted(cancel)) return _finish(aborted);
    }

    return _finish(
      'ai: stopped after ${config.maxSteps} steps without finishing.',
    );
  }

  /// Writes the horizontal rule (cyan) that frames the interaction, if the host
  /// provided one.
  void _frame() {
    final r = handlers.rule?.call();
    if (r != null) handlers.writeLine(style.rule(r));
  }

  /// Closes the interaction: a blank line, the (already-styled) [styledMessage]
  /// if any, then the closing rule. Returns [returnText] as the run's result.
  String? _finish(String? styledMessage, {String? returnText}) {
    handlers.writeLine('');
    if (styledMessage != null) handlers.writeLine(styledMessage);
    _frame();
    return returnText;
  }

  /// Asks the host for a follow-up message after the final answer. Returns the
  /// (non-empty, trimmed) message to continue the conversation, or `null` to
  /// end the agent — including when no [AgentHandlers.continueChat] is provided.
  Future<String?> _promptContinue() async {
    final c = handlers.continueChat;
    if (c == null) return null;
    final text = (await c())?.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  /// Writes a dashed magenta rule (a distinct char and color from the cyan
  /// frame rule) just before a plan, separating it from the preceding
  /// investigation output. Skipped when the host omits framing.
  void _planSeparator() {
    final r = handlers.rule?.call();
    if (r == null) return;
    handlers.writeLine('');
    handlers.writeLine(style.planRule('╌' * r.length));
  }

  /// Returns `true` when the run should stop for an abort: immediately if
  /// already confirmed, otherwise after the user confirms "Abort the AI agent?
  /// [y/N]". A declined request is cleared and the run continues.
  Future<bool> _aborted(AgentAbort cancel) async {
    if (!cancel.isRequested) return false;
    if (!cancel.isConfirmed) {
      final yes = await handlers.confirm(
        style.prompt('Abort the AI agent? [y/N] '),
      );
      if (!yes) {
        cancel.clear();
        return false;
      }
      cancel.confirm();
    }
    return true;
  }

  /// The phase for the upcoming model request. Executing once an approved plan
  /// is being run (plan mode) or the last command mutated state; planning
  /// otherwise (the first turn and any read-only investigation turn).
  AgentPhase _phaseFor({
    required AgentMode mode,
    required PlanApproval? planApproval,
  }) {
    final runningApprovedPlan =
        mode == AgentMode.plan &&
        planApproval != null &&
        planApproval != PlanApproval.cancel;
    if (runningApprovedPlan || _lastCommandMutated) return AgentPhase.executing;
    return AgentPhase.planning;
  }

  /// Tells the user once when the agent first switches to a distinct executor
  /// model, so the model change is visible.
  void _maybeAnnounceExecutor(AgentPhase phase) {
    if (phase != AgentPhase.executing || _announcedExecutor) return;
    final executor = config.modelFor(AgentPhase.executing);
    if (executor == config.modelFor(AgentPhase.planning)) return;
    _announcedExecutor = true;
    handlers.writeLine(
      style.executing('ai: switching to executor model ($executor)'),
    );
  }

  Future<_ToolOutcome> _handleToolCall(
    AiToolCall call, {
    required AgentMode mode,
    required PlanApproval? planApproval,
    required void Function(PlanApproval) onPlanApproval,
  }) async {
    switch (call.name) {
      case 'present_plan':
        return _handlePresentPlan(
          call,
          mode: mode,
          onPlanApproval: onPlanApproval,
        );
      case 'run_command':
        return _handleRunCommand(call, mode: mode, planApproval: planApproval);
      default:
        return _ToolOutcome(
          AiToolResult(
            callId: call.id,
            name: call.name,
            content: 'Unknown tool: ${call.name}',
            isError: true,
          ),
        );
    }
  }

  Future<_ToolOutcome> _handlePresentPlan(
    AiToolCall call, {
    required AgentMode mode,
    required void Function(PlanApproval) onPlanApproval,
  }) async {
    final plan = _parsePlan(call.arguments);
    _planSeparator();
    if (plan.summary != null && plan.summary!.isNotEmpty) {
      handlers.writeLine(style.planning('Plan: ${plan.summary}'));
    }
    for (var i = 0; i < plan.steps.length; i++) {
      final s = plan.steps[i];
      handlers.writeLine(style.planning('  ${i + 1}. ${s.command}'));
      if (s.explanation != null && s.explanation!.isNotEmpty) {
        handlers.writeLine(style.planning('     ${s.explanation}'));
      }
    }

    if (mode != AgentMode.plan) {
      return _ToolOutcome(
        AiToolResult(
          callId: call.id,
          name: call.name,
          content:
              'Plan acknowledged. Proceed by calling run_command for each step; '
              '$mode-mode confirmation rules apply.',
        ),
      );
    }

    final approval = await handlers.approvePlan(plan);

    // Talk: the plan is NOT approved — feed the user's notes back so the agent
    // revises and re-presents. Leave the approval state untouched.
    if (approval == PlanApproval.talk) {
      final notes = (await handlers.planNotes?.call())?.trim() ?? '';
      return _ToolOutcome(
        AiToolResult(
          callId: call.id,
          name: call.name,
          content: notes.isEmpty
              ? 'The user did not approve the plan and wants changes. Ask what '
                    'to adjust, or revise it, then call present_plan again.'
              : 'The user did not approve the plan and asks: "$notes". Revise '
                    'the plan accordingly and call present_plan again for approval.',
        ),
      );
    }

    onPlanApproval(approval);
    // A fresh approval supersedes any earlier failure: resume normal execution.
    if (approval != PlanApproval.cancel) _replanNeeded = false;
    final content = switch (approval) {
      PlanApproval.all =>
        'User approved the whole plan. Execute the steps with run_command; '
            'they will not be re-confirmed.',
      PlanApproval.stepByStep =>
        'User approved step-by-step. Execute the steps with run_command; each '
            'will be confirmed individually.',
      PlanApproval.talk => '', // handled above
      PlanApproval.cancel => 'User cancelled the plan.',
    };
    return _ToolOutcome(
      AiToolResult(callId: call.id, name: call.name, content: content),
      cancelled: approval == PlanApproval.cancel,
    );
  }

  Future<_ToolOutcome> _handleRunCommand(
    AiToolCall call, {
    required AgentMode mode,
    required PlanApproval? planApproval,
  }) async {
    final command = (call.arguments['command'] as String?)?.trim() ?? '';
    if (command.isEmpty) {
      return _ToolOutcome(
        AiToolResult(
          callId: call.id,
          name: call.name,
          content: 'No command provided.',
          isError: true,
        ),
      );
    }

    final verdict = shield.validate(command, syntax: syntax);

    // Auto-block in every mode: DENY or critical never runs.
    if (verdict.decision == CommandDecision.deny ||
        verdict.securityLevel == SecurityLevel.critical) {
      final reason = _findingsSummary(verdict);
      handlers.writeLine(style.blocked('⛔ blocked: $command'));
      handlers.writeLine(style.blocked('   $reason'));
      return _ToolOutcome(
        AiToolResult(
          callId: call.id,
          name: call.name,
          content:
              'BLOCKED by command_shield (${verdict.decision.name}/'
              '${verdict.securityLevel.name}): $reason. The command was NOT run. '
              'Do not retry it; find a safer approach or ask the user.',
          isError: true,
        ),
      );
    }

    if (!await _shouldRun(
      command,
      verdict,
      mode: mode,
      planApproval: planApproval,
    )) {
      return _ToolOutcome(
        AiToolResult(
          callId: call.id,
          name: call.name,
          content:
              'User declined to run this command. Propose an alternative or '
              'stop and explain.',
        ),
      );
    }

    handlers.writeLine(style.command('\$ $command'));
    final CommandRun run;
    try {
      run = await runner.run(command);
    } catch (e) {
      return _ToolOutcome(
        AiToolResult(
          callId: call.id,
          name: call.name,
          content: 'Execution failed: $e',
          isError: true,
        ),
      );
    }

    // Classify the executed command so the next turn picks the right model:
    // read-only probing stays on the planner; a mutating command switches to
    // the executor.
    _lastCommandMutated = !shield.analyze(command, syntax: syntax).isReadOnly;

    final out = _renderRun(run);
    // When the runner already streamed output to the terminal (live interactive
    // session), don't print it again — only the model needs the captured text.
    if (!runner.echoesToTerminal) {
      if (run.stdout.trim().isNotEmpty) {
        handlers.writeLine(run.stdout.trimRight());
      }
      if (run.stderr.trim().isNotEmpty) {
        handlers.writeLine(run.stderr.trimRight());
      }
    }

    // A failed command requires the plan to be reassessed and re-confirmed
    // before further mutating commands run.
    if (!run.ok && mode == AgentMode.plan) {
      _replanNeeded = true;
      handlers.writeLine(
        style.blocked(
          'ai: command failed (exit ${run.exitCode}) — adjust the '
          'plan and re-confirm before continuing.',
        ),
      );
    }

    return _ToolOutcome(
      AiToolResult(
        callId: call.id,
        name: call.name,
        content: run.ok
            ? out
            : '$out\n\nThis command FAILED or returned an unexpected result. '
                  'Do not continue the previous plan as-is: diagnose the cause, '
                  'then call present_plan with an adjusted plan and wait for '
                  're-approval before running further changes. The adjusted plan '
                  'is a CONTINUATION from this failed step: the earlier commands '
                  'in this conversation already ran (see their results above), so '
                  'do NOT repeat steps that already succeeded — include only the '
                  'fix for this failure and the remaining steps, unless a '
                  'completed step must be re-done to recover.',
        isError: !run.ok,
      ),
    );
  }

  /// Decides whether a (non-blocked) command may run under the active mode.
  Future<bool> _shouldRun(
    String command,
    CommandResult verdict, {
    required AgentMode mode,
    required PlanApproval? planApproval,
  }) async {
    switch (mode) {
      case AgentMode.auto:
        return true; // only DENY/critical blocks, handled earlier
      case AgentMode.standard:
        return _confirmCommand(command, verdict);
      case AgentMode.plan:
        // After a failure ([_replanNeeded]) the blanket approval no longer
        // applies: read-only diagnosis still flows, but any mutating command
        // must be re-confirmed (the agent is told to re-present an adjusted
        // plan, which clears the flag).
        if (planApproval == PlanApproval.all && !_replanNeeded) return true;
        if (planApproval == PlanApproval.stepByStep) {
          return _confirmCommand(command, verdict);
        }
        // No current blanket approval (none yet, or invalidated by a failure):
        // read-only diagnosis runs freely; mutating commands are confirmed.
        if (shield.analyze(command, syntax: syntax).isReadOnly) return true;
        return _confirmCommand(command, verdict);
    }
  }

  /// Confirms a command, supporting an "explain" answer that asks the agent to
  /// describe the command (generated lazily, only when requested) and re-prompts.
  /// Falls back to the plain yes/no [AgentHandlers.confirm] when the host did not
  /// provide [AgentHandlers.confirmCommand].
  ///
  /// The command is shown on its own output line (`Run: <cmd>`); the prompt the
  /// user answers is a single line (risk + options) — keeping it single-line
  /// avoids breaking the line editor, which repaints one line per keystroke.
  Future<bool> _confirmCommand(String command, CommandResult verdict) async {
    final header = '${style.prompt('Run:')} ${style.proposedCommand(command)}';
    final prompt = _confirmPrompt(verdict);

    final cc = handlers.confirmCommand;
    if (cc == null) {
      handlers.writeLine(header);
      return handlers.confirm(prompt);
    }
    while (true) {
      handlers.writeLine(header);
      switch (await cc(prompt)) {
        case CommandConfirm.yes:
          return true;
        case CommandConfirm.no:
          return false;
        case CommandConfirm.explain:
          await _explainCommand(command);
      }
    }
  }

  /// Asks the model for a brief explanation of [command] and prints it. Used
  /// only when the user picks the explain option, so descriptions are generated
  /// on demand rather than for every command.
  Future<void> _explainCommand(String command) async {
    try {
      final lang = (language == null || language!.trim().isEmpty)
          ? ''
          : ' Reply in ${language!.trim()}.';
      final r = await provider.chat(
        messages: [
          AiMessage.system(
            'You explain shell commands. In 1-2 short sentences, say what the '
            'command does and call out anything destructive or risky. No '
            'preamble, no code fences.$lang',
          ),
          AiMessage.user(command),
        ],
        tools: const [],
        model: config.explainModel,
      );
      final text = r.text?.trim();
      handlers.writeLine(
        style.planning(
          text == null || text.isEmpty ? '(no explanation)' : text,
        ),
      );
    } on AiProviderException catch (e) {
      handlers.writeLine(style.blocked('ai: could not explain: ${e.message}'));
    }
  }

  /// The single-line confirmation prompt: the risk tag (when not safe) and the
  /// answer options. The `Run: <cmd>` line is printed separately by
  /// [_confirmCommand]. `q` aborts the whole run; `?` explains the command.
  String _confirmPrompt(CommandResult verdict) {
    final risk = verdict.securityLevel == SecurityLevel.safe
        ? ''
        : '${style.blocked('[${verdict.securityLevel.name}]')} ';
    return '$risk${style.prompt('[y/N]  q=abort  ?=explain: ')}';
  }

  String _renderRun(CommandRun run) {
    final buf = StringBuffer('exit code: ${run.exitCode}\n');
    if (run.stdout.isNotEmpty) {
      buf.writeln('stdout:\n${_truncate(run.stdout)}');
    }
    if (run.stderr.isNotEmpty) {
      buf.writeln('stderr:\n${_truncate(run.stderr)}');
    }
    return buf.toString().trimRight();
  }

  String _truncate(String s) {
    if (s.length <= _maxToolOutputChars) return s;
    const half = _maxToolOutputChars ~/ 2;
    final omitted = s.length - _maxToolOutputChars;
    return '${s.substring(0, half)}\n…[$omitted chars truncated]…\n'
        '${s.substring(s.length - half)}';
  }

  String _findingsSummary(CommandResult verdict) {
    if (verdict.findings.isEmpty) {
      return 'flagged as ${verdict.securityLevel.name}';
    }
    return verdict.findings.map((f) => f.message).take(3).join('; ');
  }

  AgentPlan _parsePlan(Map<String, Object?> args) {
    final rawSteps = args['steps'];
    final steps = <AgentPlanStep>[];
    if (rawSteps is List) {
      for (final item in rawSteps) {
        if (item is Map) {
          final command = (item['command'] as String?)?.trim();
          if (command == null || command.isEmpty) continue;
          steps.add(
            AgentPlanStep(
              command: command,
              explanation: (item['explanation'] as String?)?.trim(),
            ),
          );
        }
      }
    }
    return AgentPlan(
      summary: (args['summary'] as String?)?.trim(),
      steps: steps,
    );
  }

  /// The system-prompt line that pins the agent's reply language, or empty when
  /// no language is configured.
  String get _languageRule => (language == null || language!.trim().isEmpty)
      ? ''
      : '\n- Always write every user-facing message (prose, plans, explanations '
            'and the final summary) in ${language!.trim()}. Keep shell commands, '
            'flags, paths and command output unchanged.';

  String _systemPrompt(AgentMode mode) {
    final cwd = environment.cwd == null
        ? ''
        : '\nWorking directory: ${environment.cwd}';
    final modeRules = switch (mode) {
      AgentMode.standard =>
        'MODE: standard. Run one command at a time with run_command. The user '
            'confirms each command before it runs; if they decline, adapt.',
      AgentMode.plan =>
        'MODE: plan. First investigate the node with read-only run_command '
            'probes (e.g. detect the OS/distro, package manager, and whether the '
            'target is already present). Then call present_plan with the full '
            'ordered list of commands. Only after the user approves do you run '
            'the mutating steps with run_command. If a step fails or behaves '
            'unexpectedly, stop, fix the plan, and call present_plan again for '
            're-approval before resuming. A re-presented plan CONTINUES from the '
            'failed step: the steps already executed (and their results) are in '
            'the conversation above — do not repeat ones that already succeeded; '
            'present only the fix and the remaining steps.',
      AgentMode.auto =>
        'MODE: auto. Investigate, then execute the necessary commands with '
            'run_command without asking for confirmation. Be careful and '
            'idempotent; dangerous commands are still auto-blocked.',
    };
    return '''
You are an AI operator embedded in OmnyShell, controlling a remote node through a non-interactive shell. Accomplish the user's goal by running commands.

Node:
  OS: ${environment.os}
  Arch: ${environment.arch}
  Hostname: ${environment.hostname}
  Shell syntax: ${syntax.name}$cwd

Rules:
- Use the run_command tool to inspect the node and to make changes; never assume facts you can verify with a command.
- No TTY is attached: always use non-interactive flags (e.g. apt-get -y, DEBIAN_FRONTEND=noninteractive) and never launch interactive editors or pagers.
- A security layer (command_shield) auto-blocks destructive/critical commands; if a command is blocked, do not retry it — choose a safer approach.
- Run one command per run_command call. Check exit codes; on failure, diagnose before continuing.
- If a command fails (non-zero exit) or returns output you did not expect, do not push ahead with the original plan: investigate the cause, then ADJUST your approach. In plan mode, call present_plan again with the corrected plan and wait for the user to re-approve before running further changes. Treat the new plan as a CONTINUATION from the point of failure: the commands already run in this conversation, and their results, are your starting state — do not re-run steps that already succeeded (they are done and may not be idempotent); plan only the fix and the steps still remaining.
- When the goal is achieved (or cannot be), reply with a brief plain-text summary and no tool call.$_languageRule

$modeRules
''';
  }
}

/// The result of handling one tool call: what to feed back to the model, and
/// whether the user cancelled (which stops the loop).
class _ToolOutcome {
  _ToolOutcome(this.result, {this.cancelled = false});

  final AiToolResult result;
  final bool cancelled;
}
