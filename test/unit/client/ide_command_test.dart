@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
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

/// Runs [line] through a registry holding `:ide`, returning what it wrote and
/// how many times it asked for the full screen. The full-screen body is never
/// invoked: it would drive the real terminal.
Future<({List<String> out, int fullScreenCalls})> _run(
  String line, {
  ClientRuntime? client,
  String? remoteCwd,
  bool interactive = true,
}) async {
  final out = <String>[];
  var calls = 0;
  final context = LocalCommandContext(
    client: client,
    node: _node(),
    startedAt: DateTime.now(),
    writeLine: out.add,
    currentRemoteCwd: remoteCwd == null ? null : () => remoteCwd,
    runFullScreen: interactive ? (body) async => calls++ : null,
  );
  await (LocalCommandRegistry()..addIdeCommand()).handle(line, context);
  return (out: out, fullScreenCalls: calls);
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
      final r = await _run(':edit ${tmp.path}');
      expect(r.out, isEmpty);
      expect(r.fullScreenCalls, 1);
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
      );
      expect(r.out, isEmpty);
      expect(r.fullScreenCalls, 1);
    });

    test('connected, an absolute path needs no remote cwd', () async {
      final r = await _run(':ide /srv/app', client: _client());
      expect(r.out, isEmpty);
      expect(r.fullScreenCalls, 1);
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
