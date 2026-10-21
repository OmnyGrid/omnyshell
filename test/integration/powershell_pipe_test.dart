@TestOn('windows')
@Tags(['windows'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

/// What a PowerShell session, started the way a node starts it, writes back
/// over the pipe for the client's protocol — the init line, a full marker,
/// then a command with a ping marker — with no client-side filtering.
///
/// It prints the raw stdout (escaped) to the test log: the record of what the
/// client has to cope with, per PowerShell edition.
void main() {
  for (final exe in ['powershell.exe', 'pwsh.exe']) {
    final path = _onPath(exe);
    test('$exe: raw output for the client protocol', () async {
      final session = await ProcessShellBackend().start(
        ShellRequest(mode: SessionMode.shell, command: path),
      );
      final out = StringBuffer();
      final sub = session.stdout.listen((b) => out.write(latin1.decode(b)));
      const dialect = PowerShellDialect();
      final marker = CwdMarker('diag');
      final lines = [
        dialect.initLine!,
        dialect.fullMarker(marker),
        dialect.wrapCommand(
          'Write-Output hello-omny',
          interactive: false,
          tail: dialect.pingMarker(marker),
        ),
      ];
      for (final line in lines) {
        session.writeStdin(utf8.encode('$line\n'));
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await session.closeStdin();
      await session.exitCode.timeout(const Duration(seconds: 30));
      await sub.cancel();

      final raw = out.toString();
      // ignore: avoid_print
      print('--- $exe raw stdout ---\n${jsonEncode(raw)}\n---');
      // The command's output and both markers arrive, whatever else does.
      expect(raw, contains('hello-omny'));
      expect(marker.token.allMatches(raw), hasLength(2));
    }, skip: path == null ? '$exe is not installed' : false);
  }
}

String? _onPath(String name) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(';')) {
    if (dir.isEmpty) continue;
    final file = File('$dir\\$name');
    if (file.existsSync()) return file.path;
  }
  return null;
}
