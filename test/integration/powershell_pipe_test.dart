@TestOn('windows')
@Tags(['windows'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/src/application/client/echo_filter.dart';
import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

/// What a PowerShell session, started the way a node starts it, writes back
/// over the pipe for the client's protocol — the init line, a full marker,
/// then a command with a ping marker — with no client-side filtering.
///
/// This is the behaviour `EchoFilter` exists for, pinned down per edition: a
/// prompt before every line PowerShell reads — `PS <location>> ` first, then
/// the session's sentinel once the init line has set it (with an empty prompt
/// function, PowerShell would write `PS>` instead) — and the line echoed after
/// it, `\n`-terminated. Should a PowerShell release change it, this fails
/// before users see the change.
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
      final prompt = marker.promptSentinel;
      final lines = [
        dialect.sessionInitLine(marker),
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
      final reason = 'raw stdout: ${jsonEncode(raw)}';
      // The default prompt, then the init line echoed after it.
      expect(
        raw,
        matches(RegExp('^PS [^\\n]*> ${RegExp.escape(lines[0])}\n')),
        reason: reason,
      );
      // Each later line echoed after the sentinel prompt the init line set.
      expect(raw, contains('\n$prompt${lines[1]}\n'), reason: reason);
      expect(raw, contains('\n$prompt${lines[2]}\n'), reason: reason);
      // The command's output and both markers, and the next prompt last.
      expect(raw, contains('hello-omny'), reason: reason);
      expect(marker.token.allMatches(raw), hasLength(2), reason: reason);
      expect(raw, endsWith('\n$prompt'), reason: reason);
      // Filtered, only the two marker lines and the command's output are
      // left: no prompt, no echoed line.
      final filtered = latin1.decode(
        EchoFilter(
          prompt: prompt,
          initLine: lines[0],
        ).filter(Uint8List.fromList(latin1.encode(raw))),
      );
      final kept = filtered.split('\n')..removeLast();
      expect(kept, hasLength(3), reason: 'filtered: ${jsonEncode(filtered)}');
      expect(kept[0], startsWith(marker.token));
      expect(kept[1], 'hello-omny\r');
      expect(kept[2], marker.token);
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
