/// How much autonomy the AI agent has when it wants to run a command.
///
/// The mode controls the confirmation contract only — it never relaxes the
/// `command_shield` gate, which auto-blocks DENY / critical commands in every
/// mode (see `AgentService`).
enum AgentMode {
  /// The agent proposes **one command at a time**; the user confirms each one
  /// before it runs.
  standard,

  /// The agent first investigates the node and presents a **full multi-step
  /// plan**; the user approves it all-at-once or steps through it one at a time.
  plan,

  /// The agent executes **autonomously with no confirmation**. `command_shield`
  /// still auto-blocks DENY / critical commands.
  auto;

  /// The wire/config token for this mode (its lowercase name).
  String get wireName => name;

  /// Decodes a token written in `ai.yaml` or `:ai mode <x>`, returning `null`
  /// for anything unrecognised so the caller can report a usage error.
  static AgentMode? tryParse(String? value) => switch (value?.trim()) {
    'standard' => AgentMode.standard,
    'plan' => AgentMode.plan,
    'auto' => AgentMode.auto,
    _ => null,
  };
}
