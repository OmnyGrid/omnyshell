import 'dart:convert';

import 'package:command_shield/command_shield.dart'
    show CommandShield, CommandSyntax;

import '../../domain/backend/shell_family.dart';
import '../ai/agent_abort.dart';
import '../ai/agent_mode.dart';
import '../ai/agent_service.dart';
import '../ai/agent_style.dart';
import '../ai/ai_config.dart';
import '../ai/command_runner.dart';
import '../ai/providers/ai_provider.dart';
import 'local_command.dart';

/// The `:ai $prompt` local command: drives a provider-agnostic AI agent that
/// investigates the node, plans and executes commands to accomplish a
/// natural-language goal, with `command_shield` gating every command.
///
/// Browser-safe: the provider, shield and config are injected, and all node
/// interaction goes through [LocalCommandContext] / [AgentCommandRunner]. The native
/// CLI wires it up via `addAiCommand()` (see `ai_commands_native.dart`).
///
/// Usage:
/// * `:ai <prompt>` — run the agent in the current mode.
/// * `:ai mode <standard|plan|auto>` — change the default mode for this session.
/// * `:ai --standard|--plan|--auto <prompt>` — one-shot mode override.
/// * `:ai status` — show provider, model and mode.
class AiCommand extends LocalCommand {
  AiCommand({
    required AiConfig config,
    required AiProvider provider,
    required CommandShield shield,
    AgentStyle style = const AgentStyle(),
    this.onModeChanged,
    this.onLanguageChanged,
  }) : _config = config,
       _provider = provider,
       _shield = shield,
       _style = style,
       _mode = config.defaultMode,
       _language = config.language;

  final AiConfig _config;
  final AiProvider _provider;
  final CommandShield _shield;
  final AgentStyle _style;

  /// Persists a mode change (e.g. to `ai.yaml`). `null` keeps it in-memory only.
  final void Function(AgentMode mode)? onModeChanged;

  /// Persists a reply-language change. `null` keeps it in-memory only.
  final void Function(String? language)? onLanguageChanged;

  AgentMode _mode;
  String? _language;

  @override
  String get name => 'ai';

  @override
  String get description =>
      'Ask an AI agent to investigate and act on the node';

  @override
  String? get usage =>
      '  :ai <prompt>                 run the agent (mode: '
      '${_mode.wireName})\n'
      '  :ai mode <standard|plan|auto>  set the default mode\n'
      '  :ai lang <language|off>      set the reply language\n'
      '  :ai --standard|--plan|--auto <prompt>  one-shot mode override\n'
      '  :ai --lang <language> <prompt>  one-shot language override\n'
      '  :ai status                   show provider, model, mode, language\n'
      '  :ai -h | --help              show this help';

  @override
  Future<void> run(LocalCommandContext context, List<String> args) async {
    if (args.isEmpty) {
      context.writeLine('Usage:\n$usage');
      return;
    }

    final first = args.first;
    if (first == '-h' || first == '--help' || first == 'help') {
      context.writeLine('Usage:\n$usage');
      return;
    }
    if (first == 'status') {
      context.writeLine(
        'ai: ${_config.provider.wireName} / ${_config.model} '
        '(mode: ${_mode.wireName})',
      );
      if (_config.plannerModel != null) {
        context.writeLine('  planner:  ${_config.plannerModel}');
      }
      if (_config.executorModel != null) {
        context.writeLine('  executor: ${_config.executorModel}');
      }
      if (_config.explainerModel != null) {
        context.writeLine('  explainer: ${_config.explainerModel}');
      }
      context.writeLine('  language: ${_language ?? '(model default)'}');
      return;
    }
    if (first == 'mode') {
      final parsed = AgentMode.tryParse(args.length > 1 ? args[1] : null);
      if (parsed == null) {
        context.writeLine('ai: usage: :ai mode <standard|plan|auto>');
        return;
      }
      _mode = parsed;
      onModeChanged?.call(parsed);
      context.writeLine('ai: mode set to ${parsed.wireName}');
      return;
    }
    if (first == 'lang' || first == 'language') {
      if (args.length < 2) {
        context.writeLine('ai: language is ${_language ?? '(model default)'}');
        return;
      }
      final value = args.sublist(1).join(' ').trim();
      final cleared = _isLanguageOff(value);
      _language = cleared ? null : value;
      onLanguageChanged?.call(_language);
      context.writeLine(
        cleared
            ? 'ai: language reset to the model default'
            : 'ai: language set to $_language',
      );
      return;
    }

    // Consume leading one-shot flags (mode and --lang) in any order.
    var mode = _mode;
    var oneShotLanguage = _language;
    var rest = args;
    while (rest.isNotEmpty) {
      final flagMode = _modeFromFlag(rest.first);
      if (flagMode != null) {
        mode = flagMode;
        rest = rest.sublist(1);
        continue;
      }
      if ((rest.first == '--lang' || rest.first == '--language') &&
          rest.length >= 2) {
        oneShotLanguage = _isLanguageOff(rest[1]) ? null : rest[1];
        rest = rest.sublist(2);
        continue;
      }
      break;
    }

    final goal = rest.join(' ').trim();
    if (goal.isEmpty) {
      context.writeLine('ai: no prompt given');
      return;
    }

    // Abort signal: Ctrl-C (via onInterruptRequest) requests an abort the loop
    // confirms; an `abort`/`q` answer at a prompt aborts directly.
    final cancel = AgentAbort();
    context.onInterruptRequest?.call(cancel.request);
    try {
      final service = _buildService(context, mode, cancel, oneShotLanguage);
      await service.run(goal, mode: mode, abort: cancel);
    } finally {
      context.onInterruptRequest?.call(null);
    }
  }

  /// Whether [answer] (already lowercased/trimmed) is an abort request.
  static bool _isAbort(String answer) => answer == 'abort' || answer == 'q';

  /// Whether [value] asks to clear the language back to the model default.
  static bool _isLanguageOff(String value) {
    final v = value.trim().toLowerCase();
    return v == 'off' || v == 'none' || v == 'default';
  }

  @override
  Future<void> dispose() async => _provider.close();

  AgentMode? _modeFromFlag(String arg) => switch (arg) {
    '--standard' => AgentMode.standard,
    '--plan' => AgentMode.plan,
    '--auto' => AgentMode.auto,
    _ => null,
  };

  AgentService _buildService(
    LocalCommandContext context,
    AgentMode mode,
    AgentAbort cancel,
    String? language,
  ) {
    final platform = context.node.platform;
    final syntax = _syntaxFor(
      context.shellFamily ?? context.session?.shellFamily ?? ShellFamily.posix,
    );

    final environment = AgentEnvironment(
      os: platform.os,
      arch: platform.arch,
      hostname: platform.hostname,
      cwd: context.currentRemoteCwd?.call(),
    );

    final handlers = AgentHandlers(
      writeLine: context.printAbove ?? context.writeLine,
      confirm: (prompt) async {
        if (context.readLine == null) return false; // non-interactive: decline
        final answer = (await context.readLine!(prompt)).trim().toLowerCase();
        if (_isAbort(answer)) {
          cancel.requestConfirmed(); // explicit answer needs no extra confirm
          return false;
        }
        return answer == 'y' || answer == 'yes';
      },
      confirmCommand: (prompt) async {
        if (context.readLine == null) return CommandConfirm.no;
        final answer = (await context.readLine!(prompt)).trim().toLowerCase();
        if (_isAbort(answer)) {
          cancel.requestConfirmed();
          return CommandConfirm.no;
        }
        if (answer == '?' || answer == 'explain') return CommandConfirm.explain;
        return (answer == 'y' || answer == 'yes')
            ? CommandConfirm.yes
            : CommandConfirm.no;
      },
      rule: context.horizontalRule,
      approvePlan: (plan) async {
        if (context.readLine == null) return PlanApproval.cancel;
        final answer = (await context.readLine!(
          _style.prompt(
            'Approve plan? [a]ll / [s]tep-by-step / [t]alk / [N]o / [q]=abort: ',
          ),
        )).trim().toLowerCase();
        if (_isAbort(answer)) {
          cancel.requestConfirmed();
          return PlanApproval.cancel;
        }
        return switch (answer) {
          'a' || 'all' => PlanApproval.all,
          's' || 'step' => PlanApproval.stepByStep,
          't' || 'talk' => PlanApproval.talk,
          _ => PlanApproval.cancel,
        };
      },
      planNotes: context.readLine == null
          ? null
          : () async => (await context.readLine!(
              _style.prompt('Notes for the agent: '),
            )).trim(),
      continueChat: context.readLine == null
          ? null
          : () async => (await context.readLine!(
              _style.prompt('Chat to continue, or [Enter] to end the agent: '),
            )).trim(),
    );

    final runInSession = context.runInSession;
    return AgentService(
      provider: _provider,
      // Prefer the live interactive session (PTY, shared cwd/env/sudo); fall
      // back to a one-off exec when the host has no live session to run in.
      runner: runInSession != null
          ? _SessionAgentCommandRunner(runInSession)
          : _ClientAgentCommandRunner(context),
      shield: _shield,
      config: _config,
      syntax: syntax,
      environment: environment,
      handlers: handlers,
      style: _style,
      language: language,
    );
  }

  CommandSyntax _syntaxFor(ShellFamily family) => switch (family) {
    ShellFamily.posix => CommandSyntax.bash,
    ShellFamily.powershell => CommandSyntax.powershell,
    ShellFamily.cmd => CommandSyntax.windowsCmd,
  };
}

/// Runs agent commands in the host's current interactive session, so they get a
/// PTY and share the session's cwd/env and cached sudo credentials. Output has
/// already streamed to the terminal, so [echoesToTerminal] is `true`.
class _SessionAgentCommandRunner implements AgentCommandRunner {
  _SessionAgentCommandRunner(this._run);

  final Future<SessionCommandResult> Function(String command) _run;

  @override
  bool get echoesToTerminal => true;

  @override
  Future<CommandRun> run(String command) async {
    final r = await _run(command);
    return CommandRun(
      exitCode: r.exitCode ?? 0, // unknown exit code → treat as success
      stdout: r.output,
      stderr: '',
    );
  }
}

/// Runs agent commands through the connected [ClientRuntime] via the exec path.
class _ClientAgentCommandRunner implements AgentCommandRunner {
  _ClientAgentCommandRunner(this.context);

  final LocalCommandContext context;

  @override
  bool get echoesToTerminal => false;

  @override
  Future<CommandRun> run(String command) async {
    final res = await context.requireClient.execute(
      nodeId: context.node.id.value,
      command: command,
      shellFamily: context.session?.shellFamily,
    );
    return CommandRun(
      exitCode: res.exitCode,
      stdout: utf8.decode(res.stdout, allowMalformed: true),
      stderr: utf8.decode(res.stderr, allowMalformed: true),
    );
  }
}
