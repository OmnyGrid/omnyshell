import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// A [ClientRuntime] that answers the Hub calls local commands make from
/// scripted values and records what it was asked, so `:ping`, `:tunnel` and
/// `:tree` can be exercised without a Hub.
class _FakeClient implements ClientRuntime {
  _FakeClient({String hubUri = 'wss://hub.example:8443/'})
    : config = ClientConfig(
        hubUri: Uri.parse(hubUri),
        credentials: const TokenCredentialProvider(
          principal: 'tester',
          token: 'tok',
        ),
      );

  @override
  final ClientConfig config;

  /// Round-trip times returned by successive [ping] calls.
  List<Duration> pings = const [Duration(milliseconds: 5)];
  var _pingIndex = 0;

  /// The tunnel returned by [openTunnel], or the error it throws.
  TunnelHandle? tunnel;
  Object? tunnelError;
  final openTunnelCalls = <Map<String, Object?>>[];

  List<TunnelInfo> tunnels = const [];
  Object? listError;

  TunnelCloseResult closeResult = const TunnelCloseResult(
    ok: true,
    message: 'closed',
  );
  Object? closeError;
  final closedRefs = <String>[];

  /// The result of [execute], or the error it throws.
  ExecResult? execResult;
  Object? execError;
  final executed = <String>[];

  @override
  Future<Duration> ping() async => pings[_pingIndex++ % pings.length];

  @override
  Future<TunnelHandle> openTunnel({
    required int targetPort,
    String nodeId = '',
    String targetHost = 'localhost',
    int? publicPort,
    bool local = false,
    bool secure = false,
  }) async {
    openTunnelCalls.add({
      'nodeId': nodeId,
      'targetPort': targetPort,
      'publicPort': publicPort,
      'secure': secure,
    });
    if (tunnelError != null) throw tunnelError!;
    return tunnel!;
  }

  @override
  Future<List<TunnelInfo>> listTunnels() async {
    if (listError != null) throw listError!;
    return tunnels;
  }

  @override
  Future<TunnelCloseResult> closeTunnel(String tunnelRef) async {
    closedRefs.add(tunnelRef);
    if (closeError != null) throw closeError!;
    return closeResult;
  }

  @override
  Future<ExecResult> execute({
    required String nodeId,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    String? cwd,
    ShellFamily? shellFamily,
  }) async {
    executed.add(command);
    if (execError != null) throw execError!;
    return execResult!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [RemoteSession] with a scripted id/shell family and a recorded [detach].
class _FakeSession implements RemoteSession {
  _FakeSession({
    String? id = 'sess-1234567890',
    this.shellFamily = ShellFamily.posix,
    this.outcome,
    this.detachError,
  }) : id = id == null ? null : SessionId(id);

  @override
  final SessionId? id;

  @override
  final ShellFamily shellFamily;

  @override
  SessionMode get mode => SessionMode.shell;

  final DetachOutcome? outcome;
  final Object? detachError;
  final detachTimeouts = <Duration?>[];

  @override
  Future<DetachOutcome> detach({Duration? timeout}) async {
    detachTimeouts.add(timeout);
    if (detachError != null) throw detachError!;
    return outcome!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NodeDescriptor _node({String id = 'n1', String os = 'linux'}) => NodeDescriptor(
  id: NodeId(id),
  displayName: id,
  platform: PlatformInfo(
    os: os,
    arch: 'x64',
    agentVersion: '1.0.0',
    hostname: 'host',
  ),
  online: true,
);

TunnelInfo _tunnelInfo({
  required String id,
  String nodeId = 'n1',
  String publicHost = '',
  int publicPort = 40001,
  int targetPort = 8080,
}) => TunnelInfo(
  tunnelId: id,
  nodeId: nodeId,
  ownerUserId: 'tester',
  targetHost: 'localhost',
  targetPort: targetPort,
  publicHost: publicHost,
  publicPort: publicPort,
  createdAt: DateTime.utc(2026),
);

ExecResult _exec(String stdout, {int exitCode = 0, String stderr = ''}) =>
    ExecResult(
      exitCode: exitCode,
      stdout: Uint8List.fromList(utf8.encode(stdout)),
      stderr: Uint8List.fromList(utf8.encode(stderr)),
    );

/// Runs [line] through the default registry and returns what it wrote.
Future<List<String>> _run(
  String line, {
  _FakeClient? client,
  RemoteSession? session,
  NodeDescriptor? node,
  String? cwd,
  void Function(LocalCommandContext context)? inspect,
}) async {
  final out = <String>[];
  final context = LocalCommandContext(
    client: client ?? _FakeClient(),
    node: node ?? _node(),
    session: session,
    startedAt: DateTime.now(),
    writeLine: out.add,
    currentRemoteCwd: cwd == null ? null : () => cwd,
  );
  await LocalCommandRegistry.withDefaults().handle(line, context);
  inspect?.call(context);
  return out;
}

void main() {
  group(':latency and :ping', () {
    test(':latency reports the round-trip time', () async {
      final client = _FakeClient()..pings = [const Duration(milliseconds: 42)];
      expect(await _run(':latency', client: client), ['RTT: 42ms']);
    });

    test(':ping without a count pings once', () async {
      final client = _FakeClient()..pings = [const Duration(milliseconds: 7)];
      expect(await _run(':ping', client: client), ['pong 7ms']);
    });

    test(':ping N numbers each reply and summarises min/avg/max', () async {
      final client = _FakeClient()
        ..pings = const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 30),
          Duration(milliseconds: 21),
        ];
      expect(await _run(':ping 3', client: client), [
        'pong 1/3 10ms',
        'pong 2/3 30ms',
        'pong 3/3 21ms',
        '--- 3 pings · min 10ms · avg 20ms · max 30ms',
      ]);
    });
  });

  group(':tunnel', () {
    test('opens a tunnel and falls back to the Hub host', () async {
      final client = _FakeClient()
        ..tunnel = const TunnelHandle(
          tunnelId: 'abcdef1234567890',
          nodeId: 'n1',
          publicHost: '',
          publicPort: 40001,
          targetPort: 8080,
        );
      final out = await _run(':tunnel 8080', client: client);
      expect(out, [
        'Tunnel abcdef12 open: hub.example:40001 -> n1:8080',
        'Close with :tunnel close abcdef12',
      ]);
      expect(client.openTunnelCalls.single, {
        'nodeId': 'n1',
        'targetPort': 8080,
        'publicPort': null,
        'secure': false,
      });
    });

    test('`open` with short flags passes the public port and TLS', () async {
      final client = _FakeClient()
        ..tunnel = const TunnelHandle(
          tunnelId: 't1',
          nodeId: 'n1',
          publicHost: 'tunnels.example',
          publicPort: 9443,
          targetPort: 3000,
          secure: true,
        );
      final out = await _run(':tunnel open 3000 -p 9443 -s', client: client);
      expect(
        out.first,
        'Tunnel t1 open: https://tunnels.example:9443 -> n1:3000',
      );
      expect(client.openTunnelCalls.single['publicPort'], 9443);
      expect(client.openTunnelCalls.single['secure'], isTrue);
    });

    test('reports an OmnyShell error by its message', () async {
      final client = _FakeClient()
        ..tunnelError = const AuthorizationException('tunnels are disabled');
      expect(await _run(':tunnel 8080', client: client), [
        'tunnel: tunnels are disabled',
      ]);
    });

    test('reports any other error via toString', () async {
      final client = _FakeClient()..tunnelError = StateError('boom');
      expect(await _run(':tunnel 8080', client: client), [
        'tunnel: Bad state: boom',
      ]);
    });

    test('ls lists only this node\'s tunnels', () async {
      final client = _FakeClient()
        ..tunnels = [
          _tunnelInfo(id: 'aaaaaaaa11', publicPort: 40001),
          _tunnelInfo(id: 'bbbbbbbb22', nodeId: 'other'),
          _tunnelInfo(
            id: 'cccccccc33',
            publicHost: 'edge.example',
            publicPort: 40003,
            targetPort: 5432,
          ),
        ];
      expect(await _run(':tunnel ls', client: client), [
        'aaaaaaaa  hub.example:40001 -> localhost:8080',
        'cccccccc  edge.example:40003 -> localhost:5432',
      ]);
    });

    test('list says so when the node has no tunnels', () async {
      final client = _FakeClient()
        ..tunnels = [_tunnelInfo(id: 'x', nodeId: 'other')];
      expect(await _run(':tunnel list', client: client), ['No tunnels on n1.']);
    });

    test('ls reports a listing error', () async {
      final client = _FakeClient()
        ..listError = const AuthorizationException('denied');
      expect(await _run(':tunnel ls', client: client), ['tunnel: denied']);
    });

    test('close reports success, a refusal and an error', () async {
      final ok = _FakeClient();
      expect(await _run(':tunnel close abc', client: ok), ['Tunnel closed.']);
      expect(ok.closedRefs, ['abc']);

      final refused = _FakeClient()
        ..closeResult = const TunnelCloseResult(
          ok: false,
          message: 'no such tunnel',
        );
      expect(await _run(':tunnel rm abc', client: refused), [
        'tunnel: no such tunnel',
      ]);

      final failing = _FakeClient()..closeError = StateError('offline');
      expect(await _run(':tunnel close abc', client: failing), [
        'tunnel: Bad state: offline',
      ]);
    });
  });

  group(':tree', () {
    const listing =
        'directory|4096|/srv/app\n'
        'regular file|100|/srv/app/a.txt\n'
        'directory|4096|/srv/app/lib\n'
        'regular file|250|/srv/app/lib/main.dart\n';

    test('renders the node listing with aggregated sizes', () async {
      final client = _FakeClient()
        ..execResult = _exec(
          '$listing'
          'regular file|50|/srv/app/b.txt\n',
        );
      // A trailing separator on the start point is dropped.
      final out = await _run(':tree /srv/app/', client: client);
      expect(out.first, startsWith('/srv/app  ['));
      expect(client.executed.single, contains("find '/srv/app' "));
      // Directories first, then files by name.
      expect(out.sublist(1, 5).map((l) => l.split('  [').first), [
        '├── lib',
        '│   └── main.dart',
        '├── a.txt',
        '└── b.txt',
      ]);
      expect(out.last, '1 directory, 3 files');
    });

    test('prunes hidden entries with GNU stat on Linux', () async {
      final client = _FakeClient()..execResult = _exec(listing);
      await _run(':tree /srv/app', client: client);
      final cmd = client.executed.single;
      expect(cmd, contains("-name '.?*' -prune"));
      expect(cmd, contains(r"stat -c '%F|%s|%n'"));
    });

    test('-a keeps hidden entries; macOS uses BSD stat', () async {
      final client = _FakeClient()..execResult = _exec(listing);
      await _run(
        ':tree /srv/app -a',
        client: client,
        node: _node(os: 'macOS'),
      );
      final cmd = client.executed.single;
      expect(cmd, isNot(contains('-prune')));
      expect(cmd, contains(r"stat -f '%HT|%z|%N'"));
    });

    test('a hidden start point is listed without pruning', () async {
      final client = _FakeClient()
        ..execResult = _exec('directory|0|/home/u/.config\n');
      await _run(':tree .config', client: client, cwd: '/home/u');
      expect(client.executed.single, isNot(contains('-prune')));
      expect(client.executed.single, contains('/home/u/.config'));
    });

    test('no path lists the remote cwd without a trailing "/."', () async {
      final client = _FakeClient()..execResult = _exec('directory|0|/home/u\n');
      final out = await _run(':tree', client: client, cwd: '/home/u/');
      expect(out.first, startsWith('/home/u  ['));
      expect(client.executed.single, contains("find '/home/u' "));
    });

    test('-L<n> in one token limits the depth', () async {
      final client = _FakeClient()..execResult = _exec(listing);
      final out = await _run(':tree /srv/app -L1', client: client);
      expect(out, isNot(contains(startsWith('│   └── main.dart'))));
      expect(out, contains(startsWith('├── lib  [')));
    });

    test('rejects a bad -L<n>, an unknown flag and a second path', () async {
      const usage = 'usage: :tree [path] [-L depth] [-a]';
      expect(await _run(':tree -Lx'), [
        '$usage  (depth must be a non-negative integer)',
      ]);
      expect(await _run(':tree -z'), [usage]);
      expect(await _run(':tree a b'), [usage]);
    });

    test('reports an exec failure, a node error and a missing path', () async {
      final thrown = _FakeClient()..execError = StateError('gone');
      expect(await _run(':tree /x', client: thrown), [
        'tree failed: Bad state: gone',
      ]);

      final stderr = _FakeClient()
        ..execResult = _exec('', exitCode: 1, stderr: 'find: /x: denied\n');
      expect(await _run(':tree /x', client: stderr), [
        'tree: find: /x: denied',
      ]);

      final silent = _FakeClient()..execResult = _exec('', exitCode: 2);
      expect(await _run(':tree /x', client: silent), ['tree: failed (exit 2)']);

      final empty = _FakeClient()..execResult = _exec('');
      expect(await _run(':tree /x', client: empty), [
        'No such remote file or directory: /x',
      ]);
    });
  });

  group(':detach', () {
    test('a session without an id cannot be detached', () async {
      expect(await _run(':detach', session: _FakeSession(id: null)), [
        'No active session to detach.',
      ]);
    });

    test('rejects a malformed timeout without detaching', () async {
      final session = _FakeSession();
      expect(await _run(':detach 5y', session: session), [
        'Invalid timeout "5y". '
            'Use a number with unit s, m, h or d (e.g. 30m, 2h, 1d).',
      ]);
      expect(session.detachTimeouts, isEmpty);
    });

    test('parses every timeout unit', () async {
      const outcome = DetachOutcome(sessionId: 's', shortId: 's');
      for (final (arg, expected) in [
        ('45s', const Duration(seconds: 45)),
        ('30m', const Duration(minutes: 30)),
        ('2H', const Duration(hours: 2)),
        ('1d', const Duration(days: 1)),
      ]) {
        final session = _FakeSession(outcome: outcome);
        await _run(':detach $arg', session: session);
        expect(session.detachTimeouts, [expected], reason: arg);
      }
    });

    test('detaches, prints the resume command and requests detach', () async {
      final expires = DateTime.utc(2026, 9, 27, 12);
      final session = _FakeSession(
        outcome: DetachOutcome(
          sessionId: 'sess-1234567890',
          shortId: 'sess-123',
          expiresAt: expires,
        ),
      );
      late LocalCommandContext ctx;
      final out = await _run(
        ':detach 1h',
        session: session,
        inspect: (c) => ctx = c,
      );
      expect(out, contains('Session detached successfully.'));
      expect(out, contains('Session ID: sess-123'));
      expect(out, contains('Expires: ${expires.toLocal()}'));
      expect(out, contains('  omnyshell sessions resume n1 sess-123'));
      expect(ctx.detachRequested, isTrue);
      expect(ctx.exitRequested, isTrue);
    });

    test('an indefinite detach prints no expiry', () async {
      final session = _FakeSession(
        outcome: const DetachOutcome(sessionId: 's', shortId: 's'),
      );
      final out = await _run(':detach', session: session);
      expect(session.detachTimeouts, [null]);
      expect(out.any((l) => l.startsWith('Expires:')), isFalse);
    });

    test('reports a failed detach and keeps the session', () async {
      final session = _FakeSession(detachError: StateError('node offline'));
      late LocalCommandContext ctx;
      final out = await _run(
        ':detach',
        session: session,
        inspect: (c) => ctx = c,
      );
      expect(out, ['Detach failed: Bad state: node offline']);
      expect(ctx.detachRequested, isFalse);
    });
  });

  group('session-aware commands', () {
    test(':info labels each shell family and shows the session', () async {
      for (final (family, label) in [
        (ShellFamily.posix, 'POSIX (sh/bash)'),
        (ShellFamily.powershell, 'PowerShell'),
        (ShellFamily.cmd, 'cmd.exe'),
      ]) {
        final out = await _run(
          ':info',
          session: _FakeSession(shellFamily: family),
        );
        expect(out, contains('Shell: $label'));
        expect(out, contains('Session: sess-1234567890 (shell)'));
      }
    });

    test(':info shows a pending session id', () async {
      final out = await _run(':info', session: _FakeSession(id: null));
      expect(out, contains('Session: (pending) (shell)'));
    });

    test(':session shows the open session and its mode', () async {
      final out = await _run(':session', session: _FakeSession());
      expect(out.take(2), ['Session: sess-1234567890', 'Mode: shell']);
    });

    test(':clear erases the screen and scrollback', () async {
      expect(await _run(':clear'), ['\x1b[2J\x1b[3J\x1b[H']);
    });
  });

  group('extension points', () {
    test('SessionCommandResult carries the exit code and output', () {
      const r = SessionCommandResult(exitCode: 3, output: 'out');
      expect(r.exitCode, 3);
      expect(r.output, 'out');
    });

    test('LocalCommand.dispose defaults to a no-op', () async {
      final registry = LocalCommandRegistry()..register(_PlainCommand());
      await expectLater(registry.dispose(), completes);
    });
  });
}

/// A command that relies on every [LocalCommand] default.
class _PlainCommand extends LocalCommand {
  @override
  String get name => 'plain';
  @override
  String get description => 'plain';
  @override
  Future<void> run(LocalCommandContext context, List<String> args) async {}
}
