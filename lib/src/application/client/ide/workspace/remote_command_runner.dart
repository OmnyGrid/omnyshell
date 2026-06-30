import 'dart:async';
import 'dart:convert';

import '../../../../domain/backend/shell_family.dart';
import '../../client_runtime.dart';
import '../terminal/command_runner.dart';

/// A [CommandRunner] that runs commands on a remote node via the connected
/// [ClientRuntime] (`executeStreaming`), decoding the byte stream into output
/// lines. `dart:io`-free, so it works in the web client too.
class RemoteCommandRunner implements CommandRunner {
  RemoteCommandRunner({
    required ClientRuntime client,
    required String nodeId,
    this.shellFamily,
  }) : _client = client,
       _nodeId = nodeId;

  final ClientRuntime _client;
  final String _nodeId;
  final ShellFamily? shellFamily;

  @override
  CommandExecution run(String command, String cwd) {
    final controller = StreamController<String>();
    final exit = Completer<int>();
    final out = _LineSink(controller.add);
    final err = _LineSink(controller.add);

    _client
        .executeStreaming(
          nodeId: _nodeId,
          command: command,
          cwd: cwd,
          shellFamily: shellFamily,
          onStdout: out.add,
          onStderr: err.add,
        )
        .then((code) {
          out.flush();
          err.flush();
          controller.close();
          if (!exit.isCompleted) exit.complete(code);
        })
        .catchError((Object e) {
          controller.addError(e);
          controller.close();
          if (!exit.isCompleted) exit.completeError(e);
        });

    // Remote exec has no cheap mid-flight cancel; kill is a best-effort no-op.
    return CommandExecution(
      output: controller.stream,
      exitCode: exit.future,
      kill: () {},
    );
  }
}

/// Accumulates UTF-8 byte chunks and emits complete lines (newline-delimited),
/// flushing any trailing partial line when the stream ends.
class _LineSink {
  _LineSink(this._emit);
  final void Function(String line) _emit;
  final StringBuffer _buf = StringBuffer();

  void add(List<int> chunk) {
    _buf.write(utf8.decode(chunk, allowMalformed: true));
    final text = _buf.toString();
    final parts = text.split('\n');
    for (var i = 0; i < parts.length - 1; i++) {
      _emit(parts[i].replaceAll('\r', ''));
    }
    _buf
      ..clear()
      ..write(parts.last);
  }

  void flush() {
    final rest = _buf.toString();
    _buf.clear();
    if (rest.isNotEmpty) _emit(rest.replaceAll('\r', ''));
  }
}
