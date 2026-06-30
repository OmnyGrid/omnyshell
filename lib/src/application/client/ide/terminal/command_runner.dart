import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A single in-flight command launched by the IDE terminal panel: a stream of
/// output [output] lines (stdout and stderr merged, one event per line), a
/// [exitCode] future, and a [kill] to terminate it early.
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
/// Abstracted so tests can inject a deterministic fake instead of spawning real
/// processes.
abstract class CommandRunner {
  CommandExecution run(String command, String cwd);
}

/// The real [CommandRunner]: runs each command through the user's shell
/// (`$SHELL -c "<command>"`, or `%ComSpec% /c` on Windows) in [cwd], streaming
/// merged stdout/stderr line by line.
class ProcessCommandRunner implements CommandRunner {
  const ProcessCommandRunner();

  @override
  CommandExecution run(String command, String cwd) {
    final controller = StreamController<String>();
    final exit = Completer<int>();
    Process? proc;

    final shell = Platform.isWindows
        ? (Platform.environment['ComSpec'] ?? 'cmd.exe')
        : (Platform.environment['SHELL'] ?? '/bin/sh');
    final args = Platform.isWindows ? ['/c', command] : ['-c', command];

    Process.start(shell, args, workingDirectory: cwd)
        .then((p) {
          proc = p;
          const decoder = Utf8Decoder(allowMalformed: true);
          const splitter = LineSplitter();
          final out = p.stdout
              .transform(decoder)
              .transform(splitter)
              .forEach(controller.add);
          final err = p.stderr
              .transform(decoder)
              .transform(splitter)
              .forEach(controller.add);
          Future.wait([out, err]).whenComplete(() async {
            final code = await p.exitCode;
            await controller.close();
            if (!exit.isCompleted) exit.complete(code);
          });
        })
        .catchError((Object e) {
          controller.addError(e);
          controller.close();
          if (!exit.isCompleted) exit.completeError(e);
        });

    return CommandExecution(
      output: controller.stream,
      exitCode: exit.future,
      kill: () => proc?.kill(),
    );
  }
}
