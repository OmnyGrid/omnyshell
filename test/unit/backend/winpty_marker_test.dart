@Tags(['pty'])
library;

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
      session.stdout.listen((c) => scans.add(marker.feed(c)));

      // Let the seeding shell settle (stty -echo; exec bash /dev/stdin).
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // Init line + prime marker, exactly as the connect loop does.
      session.writeStdin(utf8.encode('${dialect.initLine}\n'));
      session.writeStdin(utf8.encode('${dialect.fullMarker(marker)}\n'));
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // An `ls`-style read-only command followed by a ping marker.
      final cmd = dialect.wrapCommand(
        'echo HELLO',
        interactive: true,
        tail: dialect.pingMarker(marker),
      );
      session.writeStdin(utf8.encode('$cmd\n'));
      await Future<void>.delayed(const Duration(milliseconds: 1000));

      session.writeStdin(utf8.encode('exit\n'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await session.kill();

      // The marker must be recognised through winpty's escape-laden rendering.
      expect(scans.where((s) => s.completed), isNotEmpty);

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
    });
  }, skip: _winptyAvailable() ? null : 'Git bash + winpty.dll not available');
}
