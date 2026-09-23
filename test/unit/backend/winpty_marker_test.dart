@Tags(['pty'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_node.dart';
import 'package:omnyshell/src/infrastructure/backend/shell_invocation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
  group('CwdMarker through a real winpty PTY', () {
    test('markers complete with a clean, escape-free cwd', () async {
      final backend = WinptyShellBackend(fallback: ProcessShellBackend());
      final session = await backend.start(
        const ShellRequest(
          mode: SessionMode.shell,
          pty: PtySpec(term: 'xterm-256color', cols: 80, rows: 24),
        ),
      );

      final marker = CwdMarker('probe');
      const dialect = PosixShellDialect();

      final scans = <CwdScan>[];
      final completions = StreamController<CwdScan>.broadcast();
      session.stdout.listen((c) {
        final scan = marker.feed(c);
        scans.add(scan);
        if (scan.completed) completions.add(scan);
      });

      // Wait for each marker instead of sleeping a fixed time: the full marker
      // runs git through Git bash, which takes ~0.4-0.8s on an idle runner and
      // far longer while the rest of the suite runs in parallel.
      Future<CwdScan> nextCompletion() =>
          completions.stream.first.timeout(const Duration(seconds: 60));

      // Init line + prime marker, exactly as the connect loop does (input sent
      // before the seeding shell's `exec bash /dev/stdin` waits in the PTY).
      final primed = nextCompletion();
      session.writeStdin(utf8.encode('${dialect.initLine}\n'));
      session.writeStdin(utf8.encode('${dialect.fullMarker(marker)}\n'));
      final prime = await primed;

      // An `ls`-style read-only command followed by a ping marker.
      final cmd = dialect.wrapCommand(
        'echo HELLO',
        interactive: true,
        tail: dialect.pingMarker(marker),
      );
      final pinged = nextCompletion();
      session.writeStdin(utf8.encode('$cmd\n'));
      final ping = await pinged;

      session.writeStdin(utf8.encode('exit\n'));
      await session.kill();
      await completions.close();

      // The full marker reports the cwd; the ping only signals completion.
      expect(prime.cwd, isNotNull, reason: 'the prime marker reports the cwd');
      expect(ping.cwd, isNull, reason: 'a ping must not report a cwd');

      final cwds = scans.map((s) => s.cwd).whereType<String>().toList();
      expect(
        cwds,
        isNotEmpty,
        reason: 'the full prime marker should report cwd',
      );
      // No escape bytes may leak into the cwd — a polluted path breaks the
      // completion exec's chdir on the node.
      for (final c in cwds) {
        expect(
          c,
          isNot(contains('\x1b')),
          reason: 'cwd polluted by VT escapes',
        );
        expect(c, startsWith('/'), reason: 'MSYS-style cwd from Git bash');
      }
      // Two 60s marker waits need more than package:test's 30s default.
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: _winptyAvailable() ? null : 'Git bash + winpty.dll not available');
}
