@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/src/application/client/ide/tui/screen_buffer.dart';
import 'package:omnyshell/src/application/client/ide/tui/terminal_driver.dart';
import 'package:omnyshell/src/application/client/ide/workspace/remote_workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

NodeDescriptor _node() => NodeDescriptor(
  id: NodeId('n1'),
  displayName: 'n1',
  platform: const PlatformInfo(
    os: 'linux',
    arch: 'x64',
    agentVersion: '1.0.0',
    hostname: 'host',
  ),
  online: true,
);

ClientRuntime _client() => ClientRuntime(
  ClientConfig(
    hubUri: Uri.parse('wss://localhost:1/'),
    credentials: const TokenCredentialProvider(
      principal: 'tester',
      token: 'tok',
    ),
  ),
);

/// One call of the fake IDE launcher.
typedef _Launch = ({
  Workspace workspace,
  Stream<List<int>>? input,
  ShellFamily? shellFamily,
});

/// Runs [line] through a registry holding `:ide`, returning what it wrote, how
/// many times it asked for the full screen, and the launches it made. The
/// full-screen body runs against a fake launcher, never the real terminal.
Future<({List<String> out, int fullScreenCalls, List<_Launch> launches})> _run(
  String line, {
  ClientRuntime? client,
  String? remoteCwd,
  ShellFamily? shellFamily,
  bool interactive = true,
}) async {
  final out = <String>[];
  final launches = <_Launch>[];
  var calls = 0;
  const input = Stream<List<int>>.empty();
  final context = LocalCommandContext(
    client: client,
    node: _node(),
    startedAt: DateTime.now(),
    writeLine: out.add,
    currentRemoteCwd: remoteCwd == null ? null : () => remoteCwd,
    shellFamily: shellFamily,
    runFullScreen: interactive
        ? (body) async {
            calls++;
            await body(input);
          }
        : null,
  );
  Future<void> launch({
    required Workspace workspace,
    Stream<List<int>>? input,
    ShellFamily? shellFamily,
  }) async => launches.add((
    workspace: workspace,
    input: input,
    shellFamily: shellFamily,
  ));
  await (LocalCommandRegistry()..addIdeCommand(launch: launch)).handle(
    line,
    context,
  );
  return (out: out, fullScreenCalls: calls, launches: launches);
}

/// A [TerminalDriver] that quits the IDE (Ctrl-Q) as soon as it listens.
class _QuittingTerminal implements TerminalDriver {
  bool entered = false;
  bool left = false;
  int frames = 0;

  @override
  ({int cols, int rows}) get size => (cols: 80, rows: 24);
  @override
  void enter() => entered = true;
  @override
  void leave() => left = true;
  @override
  void invalidate() {}
  @override
  void present(ScreenBuffer frame, {int? cursorX, int? cursorY}) => frames++;
  @override
  Stream<List<int>> get input => Stream.value(const [0x11]);
  @override
  Stream<void> get resizeEvents => const Stream<void>.empty();
}

void main() {
  group('addIdeCommand', () {
    test('registers :ide with its :edit alias, description and usage', () {
      final registry = LocalCommandRegistry()..addIdeCommand();
      final ide = registry.commands.single;
      expect(ide, isA<IdeCommand>());
      expect(ide.name, 'ide');
      expect(ide.aliases, ['edit']);
      expect(ide.description, contains('IDE'));
      expect(ide.usage, startsWith(':ide [path]'));
      expect(ide.usage, contains('Ctrl-Q returns to the shell'));
    });
  });

  group(':ide', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('ide_command_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('needs an interactive terminal', () async {
      final r = await _run(':ide ${tmp.path}', interactive: false);
      expect(r.out, [':ide requires an interactive terminal.']);
      expect(r.fullScreenCalls, 0);
    });

    test('rejects more than one path', () async {
      final r = await _run(':ide a b');
      expect(r.out, ['usage: :ide [path]']);
      expect(r.fullScreenCalls, 0);
    });

    test('locally, opens an existing directory full-screen', () async {
      final r = await _run(':edit ${tmp.path}', shellFamily: ShellFamily.posix);
      expect(r.out, isEmpty);
      expect(r.fullScreenCalls, 1);
      final launch = r.launches.single;
      expect(launch.workspace, isA<LocalWorkspace>());
      expect(launch.workspace.rootPath, p.normalize(tmp.path));
      expect(launch.input, isNotNull, reason: "the host's forwarded stdin");
      expect(launch.shellFamily, ShellFamily.posix);
    });

    test('locally, reports a missing directory by its absolute path', () async {
      final missing = p.join(tmp.path, 'nope');
      final r = await _run(':ide $missing');
      expect(r.out, [':ide: no such directory: ${p.normalize(missing)}']);
      expect(r.fullScreenCalls, 0);
    });

    test('connected, needs a remote cwd for a relative path', () async {
      final r = await _run(':ide proj', client: _client());
      expect(
        r.out.single,
        startsWith(':ide: remote working directory unknown'),
      );
      expect(r.fullScreenCalls, 0);
    });

    test('connected, opens the remote directory full-screen', () async {
      // The remote root need not exist locally: the node's filesystem is used.
      final r = await _run(
        ':ide proj',
        client: _client(),
        remoteCwd: '/definitely/not/local',
        shellFamily: ShellFamily.powershell,
      );
      expect(r.out, isEmpty);
      expect(r.fullScreenCalls, 1);
      final launch = r.launches.single;
      expect(launch.workspace, isA<RemoteWorkspace>());
      expect(launch.workspace.rootPath, '/definitely/not/local/proj');
      expect(launch.workspace.isRemote, isTrue);
      expect(launch.shellFamily, ShellFamily.powershell);
    });

    test('connected, an absolute path needs no remote cwd', () async {
      final r = await _run(':ide /srv/app', client: _client());
      expect(r.out, isEmpty);
      expect(r.fullScreenCalls, 1);
      expect(r.launches.single.workspace.rootPath, '/srv/app');
    });

    test('nothing is launched when the command refuses', () async {
      final r = await _run(':ide ${p.join(tmp.path, 'nope')}');
      expect(r.launches, isEmpty);
    });
  });

  group('runIdeApp', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('run_ide_app_test');
      File(p.join(tmp.path, 'a.txt')).writeAsStringSync('hi\n');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('runs the IDE on the given terminal until Ctrl-Q', () async {
      final terminal = _QuittingTerminal();
      var configLoads = 0;
      await runIdeApp(
        workspace: LocalWorkspace(tmp.path),
        terminal: terminal,
        loadAiConfig: () {
          configLoads++;
          return null; // no provider: the agent panel shows setup help
        },
      );
      expect(configLoads, 1);
      expect(terminal.entered, isTrue);
      expect(terminal.left, isTrue, reason: 'terminal restored on quit');
      expect(terminal.frames, greaterThan(0));
    });

    test('builds a provider from a configured AI without calling it', () async {
      final terminal = _QuittingTerminal();
      await runIdeApp(
        workspace: LocalWorkspace(tmp.path),
        terminal: terminal,
        shellFamily: ShellFamily.cmd,
        loadAiConfig: () => const AiConfig(
          provider: AiProviderKind.anthropic,
          model: 'test-model',
          apiKey: 'test-key',
        ),
      );
      expect(terminal.left, isTrue);
    });
  });

  group('resolveLocalIdeRoot', () {
    final cwd = p.normalize(Directory.current.path);

    test('no arg / "." / "" uses the current directory', () {
      expect(resolveLocalIdeRoot(null), cwd);
      expect(resolveLocalIdeRoot(''), cwd);
      expect(resolveLocalIdeRoot('.'), cwd);
    });

    test('a relative path is made absolute against the current directory', () {
      expect(resolveLocalIdeRoot('sub'), p.join(cwd, 'sub'));
      expect(resolveLocalIdeRoot(p.join('a', 'b')), p.join(cwd, 'a', 'b'));
    });

    test('an absolute path is kept, normalized', () {
      final abs = p.join(cwd, 'a', '..', 'b');
      expect(resolveLocalIdeRoot(abs), p.join(cwd, 'b'));
      expect(resolveLocalIdeRoot(p.join(cwd, 'x')), p.join(cwd, 'x'));
    });

    test('"~" and "~/…" expand to the home directory', () {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null) return; // No home in this environment; nothing to test.
      expect(resolveLocalIdeRoot('~'), p.normalize(p.absolute(home)));
      expect(
        resolveLocalIdeRoot('~/proj'),
        p.normalize(p.absolute(p.join(home, 'proj'))),
      );
    });
  });
}
