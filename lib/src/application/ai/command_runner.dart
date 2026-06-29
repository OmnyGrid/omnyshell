/// The result of running a single command on the node.
class CommandRun {
  const CommandRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// The process exit code (0 = success).
  final int exitCode;

  /// Captured standard output (decoded text).
  final String stdout;

  /// Captured standard error (decoded text).
  final String stderr;

  /// Whether the command exited successfully.
  bool get ok => exitCode == 0;
}

/// Runs commands the agent decides to execute, decoupling the agent loop from
/// the concrete transport (`ClientRuntime`) so it stays browser-safe and
/// unit-testable with a fake.
abstract class AgentCommandRunner {
  /// Runs [command] to completion and returns its captured output.
  Future<CommandRun> run(String command);

  /// Whether the runner already streamed the command's output to the user's
  /// terminal (e.g. it ran in the live interactive session). When `true`,
  /// `AgentService` does not re-print the captured stdout/stderr.
  bool get echoesToTerminal => false;
}
