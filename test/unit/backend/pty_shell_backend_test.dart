import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_node.dart';
import 'package:portable_pty/portable_pty.dart';
import 'package:test/test.dart';

/// True when the native PTY library is installed (`dart run portable_pty:setup`)
/// and a master fd is available on this platform.
bool _ptyAvailable() {
  if (Platform.isWindows) return false;
  try {
    final p = PortablePty.open(rows: 1, cols: 1);
    final ok = p.masterFd >= 0;
    p.close();
    return ok;
  } on Object {
    return false;
  }
}

void main() {
  Future<String> collect(Stream<List<int>> stream) async =>
      utf8.decode(await stream.expand((e) => e).toList(), allowMalformed: true);

  group(
    'ProcessShellBackend PTY env-var fallback',
    () {
      final backend = ProcessShellBackend();

      test('injects TERM/COLUMNS/LINES when a PtySpec is present', () async {
        final session = await backend.start(
          const ShellRequest(
            mode: SessionMode.exec,
            command: r'echo "$COLUMNS|$LINES|$TERM"',
            pty: PtySpec(term: 'screen-256color', cols: 137, rows: 49),
          ),
        );
        expect(
          (await collect(session.stdout)).trim(),
          '137|49|screen-256color',
        );
        expect(await session.exitCode, 0);
      });

      test(
        'does not inject the spec geometry when no PtySpec is present',
        () async {
          final session = await backend.start(
            const ShellRequest(
              mode: SessionMode.exec,
              command: r'echo "term=$TERM"',
            ),
          );
          // The injected sentinel TERM must not leak into a request without a PtySpec
          // (parent COLUMNS/LINES may legitimately be inherited, so we key on TERM).
          expect(
            (await collect(session.stdout)).trim(),
            isNot(contains('screen-256color')),
          );
        },
      );
    },
    skip: Platform.isWindows ? 'POSIX shell semantics' : null,
  );

  group(
    'PtyShellBackend routing',
    () {
      test('exec (no PtySpec) goes to the pipe fallback', () async {
        final backend = PtyShellBackend(fallback: ProcessShellBackend());
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
    'PtyShellBackend real PTY',
    () {
      // Use /bin/sh (not the operator's interactive login shell) for deterministic,
      // fast startup with no theme/rc output.
      final backend = PtyShellBackend(
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
        expect(session, isA<PtyShellSession>());
        expect((await collect(session.stdout)), contains('40 120'));
        expect(await session.exitCode, 0);
      });

      test(
        'resize delivers SIGWINCH and updates the live window size',
        () async {
          final session = await backend.start(
            const ShellRequest(
              mode: SessionMode.exec,
              // Report size, then again whenever a SIGWINCH arrives, then exit.
              command: 'stty size; trap "stty size; exit 0" WINCH; sleep 10',
              pty: PtySpec(term: 'xterm-256color', cols: 100, rows: 30),
            ),
          );
          final out = collect(session.stdout);
          await Future<void>.delayed(const Duration(milliseconds: 400));
          session.resize(cols: 142, rows: 51);
          final text = await out;
          expect(text, contains('30 100')); // initial geometry
          expect(text, contains('51 142')); // after resize
          expect(await session.exitCode, 0);
        },
      );
    },
    skip: _ptyAvailable() ? null : 'native PTY library not installed',
  );
}
