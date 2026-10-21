@TestOn('windows')
@Tags(['windows'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

/// Real PowerShell sessions — Windows PowerShell 5.1 and PowerShell 7 —
/// driven through [InteractiveShellController] as the CLI drives them,
/// covering what the prompt/echo filter (`EchoFilter`) must get right beyond
/// a plain command: output shapes, errors, encodings, long lines, AI agent
/// runs, input typed into a running command, and typed-ahead lines.
///
/// Every case checks the same invariant: the user sees exactly what the
/// commands print — never the session's prompt sentinel, never a line
/// PowerShell echoed, never a marker.
void main() {
  for (final exe in ['powershell.exe', 'pwsh.exe']) {
    final path = _onPath(exe);
    group(exe, () {
      late Directory dir;
      late _Session shell;

      setUp(() async {
        dir = Directory.systemTemp.createTempSync('omny_ps_session');
        addTearDown(() => _deleteDir(dir));
        shell = await _Session.start(path!, dir.path);
        addTearDown(shell.close);
      });

      test('output without a final newline', () async {
        final out = await shell.run('Write-Host -NoNewline partial');
        expect(out, 'partial');
        shell.expectClean();
      });

      test('large output, over many chunks, arrives whole', () async {
        final out = await shell.run(r'1..3000 | ForEach-Object { "line $_" }');
        final lines = const LineSplitter().convert(out);
        expect(lines, hasLength(3000));
        expect(lines.first, 'line 1');
        expect(lines.last, 'line 3000');
        shell.expectClean();
      });

      test('an error is shown, without the protocol in it', () async {
        final out = await shell.run(r'Get-Item -LiteralPath C:\no\such\file');
        final both = '$out${shell.stderr}';
        expect(both, contains(r'C:\no\such\file'));
        // PowerShell's error display can quote the failing line (`At line:1
        // … + <line>`): the marker riding on it must not show there either.
        expect(both, isNot(contains('__omny')), reason: jsonEncode(both));
        expect(
          both,
          isNot(contains('[Console]::Out')),
          reason: jsonEncode(both),
        );
        // And the session is in step for the next command.
        expect(await shell.run('Write-Output after'), 'after\r\n');
        shell.expectClean();
      });

      test('a non-ASCII command is not echoed back', () async {
        // Echoed in the console code page rather than UTF-8: the sentinel
        // before it still marks the line, whatever its bytes.
        final out = await shell.run('Write-Output "ação ✓"');
        expect(out.trim(), isNotEmpty);
        expect(out, isNot(contains('Write-Output')));
        shell.expectClean();
      });

      test('a very long command line', () async {
        final long = 'x' * 2000;
        final out = await shell.run('Write-Output "$long"');
        expect(out, '$long\r\n');
        shell.expectClean();
      });

      test('cd moves the prompt\'s working directory', () async {
        Directory('${dir.path}\\sub').createSync();
        await shell.run('cd sub');
        expect(shell.prompt?.cwd?.toLowerCase(), endsWith(r'\sub'));
        shell.expectClean();
      });

      group('AI agent runs', () {
        test('capture the output only, with exit code 0', () async {
          final r = await shell.agent('Write-Output agent-ok');
          expect(utf8.decode(r.output), 'agent-ok\r\n');
          expect(r.exitCode, 0);
          shell.expectClean();
        });

        test('a failed cmdlet reports 1', () async {
          final r = await shell.agent(r'Get-Item -LiteralPath C:\no\such');
          expect(r.exitCode, 1);
          // The error itself is the agent's to see; the protocol is not —
          // neither the agent's prefix nor the marker, which 5.1's error
          // display would quote with the failing line.
          final captured = utf8.decode(r.output);
          expect(captured, contains(r'C:\no\such'));
          expect(captured, isNot(contains('__omny')), reason: captured);
          expect(captured, isNot(contains('LASTEXITCODE')), reason: captured);
          shell.expectClean();
        });

        test('a program reports its own exit code', () async {
          final r = await shell.agent('cmd /c exit 3');
          expect(r.exitCode, 3);
          shell.expectClean();
        });
      });

      test(
        'input typed into a command reading stdin is not swallowed',
        () async {
          // A command reading its own input from stdin, as a program does.
          // (Read-Host goes through PowerShell's console host instead, which
          // with stdin redirected does not read the pipe.)
          final done = shell.submit(
            r'Write-Host -NoNewline "Name: "; $n = [Console]::In.ReadLine(); '
            r'"got:$n"',
          );
          await shell.waitForOutput('Name: ');
          shell.type('alice\n');
          final out = await done;
          expect(out, contains('got:alice'));
          shell.expectClean();
        },
      );

      test('a line typed ahead is run, and its echo dropped', () async {
        final first = shell.submit('Start-Sleep -Milliseconds 1500');
        // Typed while the sleep runs: PowerShell reads it next, with no
        // marker of ours after it.
        shell.type('Write-Output typed-ahead\n');
        await first;
        await shell.waitForOutput('typed-ahead');
        // The session is still in step for the next command.
        expect(await shell.run('Write-Output next'), contains('next'));
        expect(shell.all, isNot(contains('Write-Output typed-ahead')));
        shell.expectClean();
      });
    }, skip: path == null ? '$exe is not installed' : false);
  }
}

/// A controller-driven PowerShell session collecting what the user would see.
class _Session {
  final InteractiveShellController controller;
  final StringBuffer _all;
  final StringBuffer _err;
  final StreamController<ShellPromptState> _prompts;
  final _outputChanged = StreamController<void>.broadcast();
  final String sentinel;
  ShellPromptState? prompt;

  _Session._(
    this.controller,
    this._all,
    this._err,
    this._prompts,
    this.sentinel,
  );

  static Future<_Session> start(String shell, String cwd) async {
    final session = await ProcessShellBackend(
      workingDirectory: cwd,
    ).start(ShellRequest(mode: SessionMode.shell, command: shell));
    final port = LocalShellSession(session);
    final marker = CwdMarker(port.id?.value);
    final all = StringBuffer();
    final err = StringBuffer();
    final prompts = StreamController<ShellPromptState>.broadcast();
    late _Session self;
    final controller = InteractiveShellController(
      session: port,
      marker: marker,
      interactive: false,
      onOutput: (b) {
        all.write(utf8.decode(b, allowMalformed: true));
        self._outputChanged.add(null);
      },
      onStderr: (b) => err.write(utf8.decode(b, allowMalformed: true)),
      onPrompt: (p) {
        self.prompt = p;
        prompts.add(p);
      },
      onPassthrough: (_) {},
    );
    self = _Session._(controller, all, err, prompts, marker.promptSentinel);
    expect(controller.shellFamily, ShellFamily.powershell);
    final first = prompts.stream.first;
    controller.start();
    await first.timeout(const Duration(seconds: 60));
    return self;
  }

  String get all => _all.toString();
  String get stderr => _err.toString();

  /// Submits [line] and returns the output it produced, once its prompt is
  /// back.
  Future<String> submit(String line) async {
    final from = _all.length;
    final next = _prompts.stream.first;
    controller.submitLine(line);
    await next.timeout(const Duration(seconds: 60));
    return all.substring(from);
  }

  Future<String> run(String line) => submit(line);

  Future<ShellRunResult> agent(String line) =>
      controller.runAgentCommand(line).timeout(const Duration(seconds: 60));

  /// Types [text] into the session, as passthrough keystrokes.
  void type(String text) => controller.sendRaw(utf8.encode(text));

  Future<void> waitForOutput(String text) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!all.contains(text)) {
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) fail('no "$text" in output: ${jsonEncode(all)}');
      await _outputChanged.stream.first.timeout(left, onTimeout: () {});
    }
  }

  /// The invariant: nothing of the protocol ever reached the user.
  void expectClean() {
    final shown = all;
    final reason = 'output: ${jsonEncode(shown)}';
    expect(shown, isNot(contains(sentinel)), reason: reason);
    expect(shown, isNot(contains('[Console]::Out')), reason: reason);
    expect(shown, isNot(contains('__omny')), reason: reason);
    expect(shown, isNot(contains('__OMNYSHELL')), reason: reason);
    expect(shown, isNot(contains('PS>')), reason: reason);
  }

  Future<void> close() async {
    await controller.close();
    await _prompts.close();
    await _outputChanged.close();
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

/// Deletes [dir], retrying: a just-exited shell can hold it a moment.
Future<void> _deleteDir(Directory dir) async {
  for (var attempt = 1; ; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= 10) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
