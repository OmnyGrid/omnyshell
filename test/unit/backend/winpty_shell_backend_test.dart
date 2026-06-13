@Tags(['pty'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_node.dart';
import 'package:omnyshell/src/infrastructure/backend/shell_invocation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// True when a Git-for-Windows bash and its `winpty.dll` (+ `winpty-agent.exe`)
/// can be found — i.e. the real-PTY path is exercisable on this host.
bool _winptyAvailable() {
  if (!Platform.isWindows) return false;
  final bash = resolveWindowsBash();
  if (bash == null) return false;
  final bashDir = p.dirname(bash);
  for (final dll in {
    p.join(bashDir, 'winpty.dll'),
    p.normalize(p.join(bashDir, '..', 'usr', 'bin', 'winpty.dll')),
  }) {
    final agent = p.join(p.dirname(dll), 'winpty-agent.exe');
    if (File(dll).existsSync() && File(agent).existsSync()) return true;
  }
  return false;
}

void main() {
  Future<String> collect(Stream<List<int>> stream) async =>
      utf8.decode(await stream.expand((e) => e).toList(), allowMalformed: true);

  group(
    'WinptyShellBackend routing',
    () {
      test('exec (no PtySpec) goes to the pipe fallback', () async {
        final backend = WinptyShellBackend(fallback: ProcessShellBackend());
        final session = await backend.start(
          const ShellRequest(mode: SessionMode.exec, command: 'echo routed'),
        );
        expect(session, isA<ProcessShellSession>());
        expect((await collect(session.stdout)).trim(), contains('routed'));
        expect(await session.exitCode, 0);
      });
    },
    skip: Platform.isWindows ? null : 'Windows-only backend',
  );

  group(
    'WinptyShellBackend real PTY',
    () {
      late WinptyShellBackend backend;
      setUp(() {
        backend = WinptyShellBackend(fallback: ProcessShellBackend());
      });

      test('shell mode runs commands; no prompt, no idle echo', () async {
        final session = await backend.start(
          const ShellRequest(
            mode: SessionMode.shell,
            pty: PtySpec(term: 'xterm-256color', cols: 80, rows: 24),
          ),
        );
        expect(session, isA<WinptyShellSession>());
        expect(session.shellFamily, ShellFamily.posix);
        // The seeding shell applies `stty -echo`; give it a moment (the client
        // sends its first command well after the shell has started).
        await Future<void>.delayed(const Duration(milliseconds: 600));
        session.writeStdin(utf8.encode('echo HELLO_42\n'));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        session.writeStdin(utf8.encode('exit\n'));
        final out = await collect(session.stdout);
        expect(out, contains('HELLO_42')); // command output forwarded
        expect(
          out,
          isNot(contains('echo HELLO_42')),
        ); // input not echoed at idle
        expect(await session.exitCode, 0);
      });

      test(
        'cooked input is echoed once echo is enabled (the Bug 2 fix)',
        () async {
          final session = await backend.start(
            const ShellRequest(
              mode: SessionMode.shell,
              pty: PtySpec(term: 'xterm-256color', cols: 80, rows: 24),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 600));
          // Enable echo (as the client's PosixShellDialect does per command), read
          // a line, then echo it back.
          session.writeStdin(utf8.encode('stty echo; read x; echo GOT=\$x\n'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          session.writeStdin(utf8.encode('typedinput\n'));
          await Future<void>.delayed(const Duration(milliseconds: 600));
          session.writeStdin(utf8.encode('exit\n'));
          final out = await collect(session.stdout);
          expect(out, contains('GOT=typedinput')); // read captured the input
          // The tty echoed the typed line, so it appears twice (echo + result).
          expect('typedinput'.allMatches(out).length, greaterThanOrEqualTo(2));
          await session.kill();
        },
      );

      test('resize does not throw', () async {
        final session = await backend.start(
          const ShellRequest(
            mode: SessionMode.shell,
            pty: PtySpec(term: 'xterm-256color', cols: 80, rows: 24),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        session.resize(cols: 120, rows: 40); // winpty_set_size — must not throw
        session.writeStdin(utf8.encode('exit\n'));
        await collect(session.stdout);
        expect(await session.exitCode, 0);
      });
    },
    skip: _winptyAvailable() ? null : 'Git bash + winpty.dll not available',
  );
}
