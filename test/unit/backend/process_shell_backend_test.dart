import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

void main() {
  final backend = ProcessShellBackend();

  Future<String> collect(Stream<List<int>> stream) async =>
      utf8.decode(await stream.expand((e) => e).toList());

  group('ProcessShellBackend', () {
    test('exec runs a command through the shell and streams stdout', () async {
      final session = await backend.start(
        const ShellRequest(
          mode: SessionMode.exec,
          command: 'echo hello-omnyshell',
        ),
      );
      final out = await collect(session.stdout);
      final code = await session.exitCode;
      expect(out.trim(), 'hello-omnyshell');
      expect(code, 0);
    });

    test('propagates a non-zero exit code', () async {
      final session = await backend.start(
        const ShellRequest(mode: SessionMode.exec, command: 'exit 3'),
      );
      expect(await session.exitCode, 3);
    });

    test('runs a program directly when args are provided', () async {
      final session = await backend.start(
        const ShellRequest(
          mode: SessionMode.exec,
          command: 'echo',
          args: ['direct-args'],
        ),
      );
      expect((await collect(session.stdout)).trim(), 'direct-args');
    });

    test('forwards stdin to an interactive shell', () async {
      final session = await backend.start(
        const ShellRequest(mode: SessionMode.shell),
      );
      session.writeStdin(utf8.encode('echo from-stdin\n'));
      await session.closeStdin();
      final out = await collect(session.stdout);
      expect(out, contains('from-stdin'));
      await session.exitCode;
    });
  }, skip: Platform.isWindows ? 'POSIX shell semantics' : null);
}
