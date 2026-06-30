@Tags(['pty'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

/// True when the system `script(1)` utility is available (POSIX only).
bool _scriptAvailable() {
  if (Platform.isWindows) return false;
  return File('/usr/bin/script').existsSync() ||
      File('/bin/script').existsSync();
}

void main() {
  Future<String> collect(Stream<List<int>> stream) async =>
      utf8.decode(await stream.expand((e) => e).toList(), allowMalformed: true);

  group(
    'ScriptPtyShellBackend routing',
    () {
      test('exec (no PtySpec) goes to the pipe fallback', () async {
        final backend = ScriptPtyShellBackend(fallback: ProcessShellBackend());
        final session = await backend.start(
          const ShellRequest(mode: SessionMode.exec, command: 'echo routed'),
        );
        expect(session, isA<ProcessShellSession>());
        expect((await collect(session.stdout)).trim(), 'routed');
        expect(await session.exitCode, 0);
      });
    },
    skip: Platform.isWindows ? 'POSIX shell semantics' : null,
  );

  group(
    'ScriptPtyShellBackend real PTY',
    () {
      // Use /bin/sh for deterministic, fast startup with no rc/theme output.
      final backend = ScriptPtyShellBackend(
        defaultShell: '/bin/sh',
        fallback: ProcessShellBackend(defaultShell: '/bin/sh'),
      );

      test('allocates a real terminal at the requested geometry', () async {
        final session = await backend.start(
          const ShellRequest(
            mode: SessionMode.exec,
            command: 'stty size', // prints "rows cols" only on a real tty
            pty: PtySpec(term: 'xterm-256color', cols: 120, rows: 40),
          ),
        );
        expect(session, isA<ScriptPtyShellSession>());
        expect(await collect(session.stdout), contains('40 120'));
        expect(await session.exitCode, 0);
      });

      test('passes the child exit code through', () async {
        final session = await backend.start(
          const ShellRequest(
            mode: SessionMode.exec,
            command: 'exit 7',
            pty: PtySpec(term: 'xterm-256color', cols: 80, rows: 24),
          ),
        );
        // Drain output so the process can finish cleanly.
        await collect(session.stdout);
        expect(await session.exitCode, 7);
      });

      test('shell mode shows no prompt and does not echo input', () async {
        final session = await backend.start(
          const ShellRequest(
            mode: SessionMode.shell,
            pty: PtySpec(term: 'xterm-256color', cols: 80, rows: 24),
          ),
        );
        // The wrapper disables echo before exec; give the child a moment to apply
        // `stty -echo` before sending input (interactively, the client sends its
        // first command well after the shell has started, so echo is already off).
        await Future<void>.delayed(const Duration(milliseconds: 500));
        session.writeStdin(utf8.encode('echo HELLO_42\n'));
        await session.closeStdin();
        final out = await collect(session.stdout);
        // The command output is forwarded...
        expect(out, contains('HELLO_42'));
        // ...but the shell prints no prompt and never echoes the command line.
        expect(out, isNot(contains('echo HELLO_42')));
        expect(out, isNot(contains(r'$ ')));
        expect(await session.exitCode, 0);
      });

      test(
        'resize updates the live terminal geometry (stty on the PTS)',
        () async {
          final session = await backend.start(
            const ShellRequest(
              mode: SessionMode.exec,
              // Report the size only AFTER the resize has had time to land.
              command: 'sleep 1; stty size',
              pty: PtySpec(term: 'xterm-256color', cols: 100, rows: 30),
            ),
          );
          // Let the wrapper record its controlling-tty path, then resize the live
          // PTY by setting the window size on that PTS with `stty` (no FFI).
          await Future<void>.delayed(const Duration(milliseconds: 300));
          session.resize(cols: 142, rows: 51);
          final out = await collect(session.stdout);
          expect(out, contains('51 142')); // the new geometry, not the initial
          expect(out, isNot(contains('30 100')));
          expect(await session.exitCode, 0);
        },
      );

      test('resize before the tty path is recorded is a safe no-op', () async {
        // A session constructed without a tty file (the prior behaviour) must
        // still accept resize without throwing.
        final session = ScriptPtyShellSession(
          await Process.start('sleep', ['0']),
        );
        expect(() => session.resize(cols: 80, rows: 24), returnsNormally);
        await session.exitCode;
      });
    },
    skip: _scriptAvailable() ? null : 'system script(1) not available',
  );
}
