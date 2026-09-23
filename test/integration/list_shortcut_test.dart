@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Drives an [InteractiveShellController] over a real shell the way the CLI
/// does, collecting the marker-stripped output of each submitted line.
class _ShellDriver {
  final _out = StringBuffer();
  final _prompts = StreamController<ShellPromptState>.broadcast();
  late final InteractiveShellController controller;

  _ShellDriver(ShellSessionPort session) {
    controller = InteractiveShellController(
      session: session,
      // A pipe-backed shell has no terminal echo to toggle.
      interactive: false,
      onOutput: (bytes) => _out.write(utf8.decode(bytes, allowMalformed: true)),
      onPrompt: _prompts.add,
      onPassthrough: (_) {},
    );
  }

  /// Starts the controller and waits for the first prompt.
  Future<void> start() async {
    final prompt = _prompts.stream.first;
    controller.start();
    await prompt.timeout(const Duration(seconds: 30));
  }

  /// Submits [line] and returns the output produced until the next prompt.
  Future<String> run(String line) async {
    _out.clear();
    final prompt = _prompts.stream.first;
    controller.submitLine(line);
    await prompt.timeout(const Duration(seconds: 30));
    return _out.toString();
  }

  Future<void> close() async {
    await controller.close();
    await _prompts.close();
  }
}

/// The first executable named one of [names] on `PATH`, or `null`.
String? _onPath(List<String> names) {
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in (Platform.environment['PATH'] ?? '').split(sep)) {
    if (dir.isEmpty) continue;
    for (final name in names) {
      final file = File('$dir${Platform.pathSeparator}$name');
      if (file.existsSync()) return file.path;
    }
  }
  return null;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omnyshell-list-shortcut');
    File('${dir.path}/.hidden').writeAsStringSync('secret');
    // 5000 bytes renders as `4.9K` in every human-readable format under test.
    File('${dir.path}/visible.txt').writeAsStringSync('x' * 5000);
    Directory('${dir.path}/sub').createSync();
    File('${dir.path}/sub/inner.txt').writeAsStringSync('inner');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<_ShellDriver> localShell({String? shell}) async {
    final backend = ProcessShellBackend(workingDirectory: dir.path);
    // The request's command picks the shell: on Windows, shell mode otherwise
    // prefers Git Bash whatever the backend's default shell is.
    final session = await backend.start(
      ShellRequest(mode: SessionMode.shell, command: shell),
    );
    final driver = _ShellDriver(LocalShellSession(session));
    addTearDown(driver.close);
    await driver.start();
    return driver;
  }

  group('POSIX shell', () {
    late _ShellDriver shell;

    setUp(() async => shell = await localShell());

    test('`l` lists hidden entries with human-readable sizes', () async {
      final out = await shell.run('l');
      expect(out, contains('.hidden'));
      expect(out, contains('visible.txt'));
      expect(out, contains('sub'));
      expect(out, matches(RegExp(r'\s\.\.$', multiLine: true)));
      expect(out, matches(RegExp(r'\b4\.9K\b')));
      expect(out, isNot(contains('not found')));
    });

    test('`l <path>` lists that path', () async {
      final out = await shell.run('l sub');
      expect(out, contains('inner.txt'));
      expect(out, isNot(contains('visible.txt')));
    });

    test('`l` output can be piped', () async {
      final out = await shell.run('l | grep visible');
      expect(out, contains('visible.txt'));
      expect(out, isNot(contains('.hidden')));
    });

    test('words that merely start with `l` are not expanded', () async {
      final out = await shell.run('ls');
      expect(out, contains('visible.txt'));
      expect(out, isNot(contains('.hidden')));
    });
  }, onPlatform: const {'windows': Skip('POSIX shell')});

  group('PowerShell', () {
    final pwsh = _onPath(['pwsh', 'pwsh.exe', 'powershell.exe']);

    test(
      '`l` lists hidden entries with a human-readable Size column',
      () async {
        final shell = await localShell(shell: pwsh);
        expect(shell.controller.shellFamily, ShellFamily.powershell);
        final out = await shell.run('l');
        expect(out, contains('Size'));
        expect(out, contains('.hidden'));
        expect(out, contains('visible.txt'));
        expect(out, contains('sub'));
        expect(out, matches(RegExp(r'\b4\.9K\b')));
        expect(out, isNot(contains('5000')));

        final sub = await shell.run('l sub');
        expect(sub, contains('inner.txt'));
        expect(sub, isNot(contains('visible.txt')));
      },
      skip: pwsh == null ? 'PowerShell is not installed' : false,
      // Also selected by the Windows CI job, where powershell.exe is present.
      tags: 'windows',
    );
  });

  group('cmd.exe', () {
    test(
      '`l` lists hidden entries',
      () async {
        // Mark the dot-file hidden so plain `dir` would omit it.
        Process.runSync('attrib', ['+h', '${dir.path}\\.hidden']);
        final shell = await localShell(shell: 'cmd.exe');
        expect(shell.controller.shellFamily, ShellFamily.cmd);
        final out = await shell.run('l');
        expect(out, contains('.hidden'));
        expect(out, contains('visible.txt'));

        final sub = await shell.run('l sub');
        expect(sub, contains('inner.txt'));
        expect(sub, isNot(contains('visible.txt')));
      },
      testOn: 'windows',
      tags: 'windows',
    );
  });

  group('through the Hub', () {
    late TestCluster cluster;

    setUp(() async => cluster = await TestCluster.start());
    tearDown(() async => cluster.dispose());

    test('`l` runs on the node and lists its directory', () async {
      await cluster.startNode(
        id: 'web-01',
        labels: {'allow-roles': 'developer'},
        backend: ProcessShellBackend(workingDirectory: dir.path),
      );
      final client = await cluster.connectClient(
        token: 'dev-token',
        principal: 'dev',
      );
      final session = await client.openSession(
        nodeId: 'web-01',
        mode: SessionMode.shell,
      );
      final shell = _ShellDriver(session);
      addTearDown(shell.close);
      await shell.start();

      final out = await shell.run('l');
      expect(out, contains('.hidden'));
      expect(out, contains('visible.txt'));
      expect(out, matches(RegExp(r'\b4\.9K\b')));
    });
  }, onPlatform: const {'windows': Skip('POSIX shell')});
}
