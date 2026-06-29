/// Maps the agent's output categories to display styling.
///
/// The base class is a no-op (returns text unchanged), so the agent core stays
/// presentation-agnostic and browser-safe. The native CLI injects
/// [AnsiAgentStyle] when colors are enabled; a web client can supply its own.
class AgentStyle {
  const AgentStyle();

  /// Planner-phase prose: investigation, reasoning, plan presentation.
  String planning(String text) => text;

  /// Executor-phase prose: carrying out an approved/decided action.
  String executing(String text) => text;

  /// A command that is being executed (e.g. the `$ apt-get install …` echo).
  String command(String text) => text;

  /// A command being proposed for confirmation (the `Run: <cmd>` line) — a
  /// distinct color from an executing [command] so the two read differently.
  String proposedCommand(String text) => text;

  /// An interactive prompt asking the user to confirm or approve.
  String prompt(String text) => text;

  /// A blocked/refused notice (e.g. a command_shield denial).
  String blocked(String text) => text;

  /// The horizontal rule that frames the start and end of an agent interaction.
  String rule(String text) => text;
}

/// ANSI-colored [AgentStyle] for terminals.
///
/// planning = cyan, executing = green, command = yellow, prompt = magenta,
/// blocked = red. Pure string manipulation (no `dart:io`), so it remains
/// browser-safe; the host decides whether to use it.
class AnsiAgentStyle extends AgentStyle {
  const AnsiAgentStyle();

  /// The ASCII escape (0x1B), built from its code point to avoid a literal
  /// control byte in source.
  static final String _esc = String.fromCharCode(0x1b);

  /// Wraps [text] in an SGR color [code] and a reset.
  String _sgr(int code, String text) => '$_esc[${code}m$text$_esc[0m';

  @override
  String planning(String text) => _sgr(36, text); // cyan

  @override
  String executing(String text) => _sgr(32, text); // green

  @override
  String command(String text) => _sgr(32, text); // green (executing)

  @override
  String proposedCommand(String text) => _sgr(33, text); // yellow (confirming)

  @override
  String prompt(String text) => _sgr(35, text); // magenta

  @override
  String blocked(String text) => _sgr(31, text); // red

  @override
  String rule(String text) => _sgr(36, text); // cyan
}
