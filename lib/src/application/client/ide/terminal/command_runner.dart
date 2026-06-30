import 'dart:async';

/// A single in-flight command launched by the IDE terminal panel: a stream of
/// output [output] lines (stdout and stderr merged, one event per line), a
/// [exitCode] future, and a [kill] to terminate it early.
///
/// This file is `dart:io`-free so the IDE engine stays web-compilable; the
/// process-backed runner lives in `process_command_runner.dart` and the
/// remote runner in `../workspace/remote_command_runner.dart`.
class CommandExecution {
  CommandExecution({
    required this.output,
    required this.exitCode,
    required void Function() kill,
  }) : _kill = kill;

  /// Output lines as they arrive (stdout and stderr merged).
  final Stream<String> output;

  /// Completes with the process exit code once it finishes.
  final Future<int> exitCode;

  final void Function() _kill;

  /// Terminates the underlying process, if still running.
  void kill() => _kill();
}

/// Runs a shell command line and exposes its output as a [CommandExecution].
/// Abstracted so the IDE can target a local process, a remote node, or a fake
/// in tests.
abstract class CommandRunner {
  CommandExecution run(String command, String cwd);
}
