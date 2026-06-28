import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// A [Clock] frozen at a fixed instant so duration/latency output is
/// deterministic in tests.
class _FixedClock implements Clock {
  _FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

/// The full CLI command set: the browser-safe defaults plus the file-transfer
/// commands (`:download`, `:upload`, `:drive`) the native CLI installs.
LocalCommandRegistry fullRegistry() =>
    LocalCommandRegistry.withDefaults()..addFileTransferCommands();

LocalCommandContext _context(
  List<String> out, {
  Principal? principal,
  NodeDescriptor? node,
  DateTime? startedAt,
  Clock clock = const SystemClock(),
}) => LocalCommandContext(
  client: ClientRuntime(
    ClientConfig(
      hubUri: Uri.parse('wss://localhost:1/'),
      credentials: const TokenCredentialProvider(
        principal: 'tester',
        token: 'tok',
      ),
    ),
  ),
  node:
      node ??
      NodeDescriptor(
        id: NodeId('n1'),
        displayName: 'n1',
        platform: const PlatformInfo(
          os: 'linux',
          arch: 'x64',
          agentVersion: '1.0.0',
          hostname: 'host',
        ),
        online: true,
      ),
  principal: principal,
  startedAt: startedAt ?? DateTime.now(),
  clock: clock,
  writeLine: out.add,
);

void main() {
  group('LocalCommandRegistry.isLocalCommand', () {
    final registry = fullRegistry();

    test('treats a `:`-prefixed line as a local command', () {
      expect(registry.isLocalCommand(':help'), isTrue);
      expect(registry.isLocalCommand('  :exit'), isTrue);
    });

    test('does not intercept an absolute path like /bin/bash', () {
      // This is the regression the `:` prefix fixes: a `/`-prefixed line is
      // ordinary shell input and must reach the remote shell untouched.
      expect(registry.isLocalCommand('/bin/bash'), isFalse);
      expect(registry.isLocalCommand('/usr/bin/env python'), isFalse);
    });

    test('does not intercept plain commands', () {
      expect(registry.isLocalCommand('ls -la'), isFalse);
    });
  });

  group('LocalCommandRegistry.handle', () {
    test(':help lists the commands with the `:` prefix', () async {
      final out = <String>[];
      final registry = fullRegistry();

      final handled = await registry.handle(':help', _context(out));

      expect(handled, isTrue);
      expect(out.first, startsWith('OmnyShell v'));
      expect(out, contains('Local commands:'));
      expect(out.any((l) => l.contains(':help')), isTrue);
      expect(out.any((l) => l.contains(':exit')), isTrue);
    });

    test(':exit requests the session to end', () async {
      final out = <String>[];
      final context = _context(out);

      final handled = await fullRegistry().handle(':exit', context);

      expect(handled, isTrue);
      expect(context.exitRequested, isTrue);
    });

    test('an unknown command is reported with the `:` prefix', () async {
      final out = <String>[];

      final handled = await fullRegistry().handle(':nope', _context(out));

      expect(handled, isTrue);
      expect(out, contains('Unknown command: :nope'));
    });

    test(':ping rejects a non-positive or non-numeric count', () async {
      for (final bad in [':ping 0', ':ping -1', ':ping abc']) {
        final out = <String>[];
        await fullRegistry().handle(bad, _context(out));
        expect(
          out.single,
          'usage: :ping [count] (count must be a positive integer)',
          reason: bad,
        );
      }
    });

    test(':info reports node, hub and platform fields', () async {
      final out = <String>[];
      await fullRegistry().handle(':info', _context(out));
      expect(out.any((l) => l.startsWith('Node: n1')), isTrue);
      expect(out.any((l) => l == 'OS: linux'), isTrue);
      expect(out.any((l) => l == 'Hub: wss://localhost:1/'), isTrue);
      // Without an open session the shell-family line is omitted, not an error.
      expect(out.any((l) => l.startsWith('Shell:')), isFalse);
      expect(out.any((l) => l.startsWith('Session Duration:')), isTrue);
    });

    test(':help lists the :tree command', () async {
      final out = <String>[];
      await fullRegistry().handle(':help', _context(out));
      expect(out.any((l) => l.contains(':tree')), isTrue);
    });

    test(':tree rejects a bad -L depth without touching the network', () async {
      for (final bad in [':tree -L abc', ':tree -L -1', ':tree -L']) {
        final out = <String>[];
        await fullRegistry().handle(bad, _context(out));
        expect(
          out.single,
          'usage: :tree [path] [-L depth] [-a]  '
          '(depth must be a non-negative integer)',
          reason: bad,
        );
      }
    });
  });

  group('parseStatLines', () {
    test('parses GNU and BSD type words and skips blank lines', () {
      const stdout =
          'directory|4096|/srv\n'
          '\n'
          'regular file|10|/srv/a.txt\n'
          'Directory|4096|/srv/sub\n'
          'Regular File|20|/srv/sub/b.txt\n'
          'symbolic link|7|/srv/link\n';
      final entries = parseStatLines(stdout);
      expect(entries, hasLength(5));
      expect(entries[0], (
        path: '/srv',
        size: 4096,
        isDir: true,
        isLink: false,
      ));
      expect(entries[1], (
        path: '/srv/a.txt',
        size: 10,
        isDir: false,
        isLink: false,
      ));
      expect(entries[3], (
        path: '/srv/sub/b.txt',
        size: 20,
        isDir: false,
        isLink: false,
      ));
      expect(entries[2].isDir, isTrue); // `/srv/sub`
      expect(entries.last, (
        path: '/srv/link',
        size: 7,
        isDir: false,
        isLink: true,
      ));
    });

    test('preserves a `|` in the path', () {
      final entries = parseStatLines('regular file|3|/srv/a|b.txt\n');
      expect(entries.single.path, '/srv/a|b.txt');
      expect(entries.single.size, 3);
    });
  });

  group('renderTree', () {
    const entries = <StatEntry>[
      (path: '/srv', size: 4096, isDir: true, isLink: false),
      (path: '/srv/a.txt', size: 1024, isDir: false, isLink: false),
      (path: '/srv/sub', size: 4096, isDir: true, isLink: false),
      (path: '/srv/sub/b.txt', size: 2048, isDir: false, isLink: false),
    ];

    test('aggregates directory sizes and lists directories first', () {
      final lines = renderTree('/srv', entries, maxDepth: 0);
      expect(lines.first, '/srv  [3.0 KB]'); // 1024 + 2048
      // `sub` (a directory) is listed before the `a.txt` file.
      expect(lines[1], '├── sub  [2.0 KB]');
      expect(lines[2], '│   └── b.txt  [2.0 KB]');
      expect(lines[3], '└── a.txt  [1.0 KB]');
      expect(lines, contains('1 directory, 2 files'));
    });

    test('collapses subtrees deeper than maxDepth but keeps their total', () {
      final lines = renderTree('/srv', entries, maxDepth: 1);
      expect(lines, contains('├── sub  [2.0 KB]'));
      // b.txt lives at depth 2 and must not be rendered.
      expect(lines.any((l) => l.contains('b.txt')), isFalse);
      // Only the directory shown at depth 1 is counted.
      expect(lines, contains('1 directory, 1 file'));
    });

    test('renders a symlink as a non-followed leaf', () {
      const withLink = <StatEntry>[
        (path: '/srv', size: 4096, isDir: true, isLink: false),
        (path: '/srv/link', size: 11, isDir: false, isLink: true),
      ];
      final lines = renderTree('/srv', withLink, maxDepth: 0);
      expect(lines, contains('└── link ->  [11 B]'));
    });
  });

  group('LocalCommandRegistry registration', () {
    test('register throws on a duplicate name', () {
      final registry = fullRegistry();
      expect(
        () => registry.register(_StubCommand('help')),
        throwsArgumentError,
      );
    });

    test('register throws on a name colliding with an existing alias', () {
      // `quit` is a built-in alias of `:exit`.
      final registry = fullRegistry();
      expect(
        () => registry.register(_StubCommand('quit')),
        throwsArgumentError,
      );
    });

    test('commands are de-duplicated by identity and sorted by name', () {
      final registry = LocalCommandRegistry();
      registry.register(_StubCommand('zeta', aliases: ['z']));
      registry.register(_StubCommand('alpha'));
      final names = registry.commands.map((c) => c.name).toList();
      // The aliased command appears once despite two registry keys.
      expect(names, ['alpha', 'zeta']);
    });

    test('an alias dispatches to its command', () async {
      // `:quit` is an alias of `:exit` and must request exit.
      final out = <String>[];
      final context = _context(out);
      final handled = await fullRegistry().handle(':quit', context);
      expect(handled, isTrue);
      expect(context.exitRequested, isTrue);
    });

    test('a blank `:` line is treated as handled but runs nothing', () async {
      final out = <String>[];
      final handled = await fullRegistry().handle(':   ', _context(out));
      expect(handled, isTrue);
      expect(out, isEmpty);
    });

    test('handle returns false for a non-local line', () async {
      final out = <String>[];
      final handled = await fullRegistry().handle('ls -la', _context(out));
      expect(handled, isFalse);
      expect(out, isEmpty);
    });
  });

  group('context-reading commands', () {
    Future<List<String>> run(
      String line, {
      Principal? principal,
      NodeDescriptor? node,
      Clock clock = const SystemClock(),
      DateTime? startedAt,
    }) async {
      final out = <String>[];
      await fullRegistry().handle(
        line,
        _context(
          out,
          principal: principal,
          node: node,
          clock: clock,
          startedAt: startedAt,
        ),
      );
      return out;
    }

    test(':os, :arch and :host echo the node platform fields', () async {
      expect(await run(':os'), ['linux']);
      expect(await run(':arch'), ['x64']);
      expect(await run(':host'), ['host']);
    });

    test(':whoami reports the principal and sorted roles', () async {
      final out = await run(
        ':whoami',
        principal: Principal(
          id: PrincipalId('alice'),
          displayName: 'Alice',
          roles: const {'developer', 'admin'},
        ),
      );
      expect(out, ['Alice (alice)', 'Roles: admin, developer']);
    });

    test(':whoami without a principal reports not authenticated', () async {
      expect(await run(':whoami'), ['Not authenticated']);
    });

    test(':node prints the id and, when present, labels', () async {
      expect(await run(':node'), ['Node: n1 (n1)']);

      final labelled = NodeDescriptor(
        id: NodeId('n2'),
        displayName: 'web',
        platform: const PlatformInfo(
          os: 'linux',
          arch: 'arm64',
          agentVersion: '1.0.0',
          hostname: 'h',
        ),
        online: true,
        labels: const {'env': 'prod', 'region': 'eu'},
      );
      final out = await run(':node', node: labelled);
      expect(out, contains('Node: n2 (web)'));
      expect(out, contains('Labels: env=prod, region=eu'));
    });

    test(':capabilities reports advertised shells/features/sessions', () async {
      final node = NodeDescriptor(
        id: NodeId('n1'),
        displayName: 'n1',
        platform: const PlatformInfo(
          os: 'linux',
          arch: 'x64',
          agentVersion: '1.0.0',
          hostname: 'host',
        ),
        online: true,
        capabilities: const NodeCapabilities(
          shells: ['bash', 'sh'],
          features: ['exec', 'shell'],
          maxSessions: 7,
        ),
      );
      final out = await run(':capabilities', node: node);
      expect(out, [
        'Shells: bash, sh',
        'Features: exec, shell',
        'Max sessions: 7',
      ]);
    });

    test(':capabilities without advertised caps says so', () async {
      expect(await run(':capabilities'), ['No capabilities advertised']);
    });

    test(':session without an open session reports (none)', () async {
      final clock = _FixedClock(DateTime.utc(2026, 1, 1, 0, 1, 5));
      final out = await run(
        ':session',
        clock: clock,
        startedAt: DateTime.utc(2026, 1, 1),
      );
      expect(out, ['Session: (none)', 'Mode: (none)', 'Duration: 00:01:05']);
    });

    test(':info renders the UID line and a fixed session duration', () async {
      final node = NodeDescriptor(
        id: NodeId('n1'),
        uid: OmnyUid('nod_abc123'),
        displayName: 'n1',
        platform: const PlatformInfo(
          os: 'linux',
          arch: 'x64',
          agentVersion: '1.0.0',
          hostname: 'host',
        ),
        online: true,
        labels: const {'env': 'prod'},
      );
      final out = await run(
        ':info',
        node: node,
        clock: _FixedClock(DateTime.utc(2026, 1, 1, 1, 2, 3)),
        startedAt: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('UID: nod_abc123'));
      expect(out, contains('Labels: env=prod'));
      expect(out, contains('Session Duration: 01:02:03'));
    });
  });

  group('argument validation (no network)', () {
    Future<String> single(String line) async {
      final out = <String>[];
      await fullRegistry().handle(line, _context(out));
      expect(out, hasLength(1), reason: line);
      return out.single;
    }

    test(':tunnel with no args prints usage', () async {
      expect(
        await single(':tunnel'),
        'usage: :tunnel <port> [--public-port N] [--secure] | :tunnel ls | '
        ':tunnel close <id>',
      );
    });

    test(':tunnel rejects an out-of-range or missing port', () async {
      const portUsage =
          'usage: :tunnel <port> [--public-port N] [--secure] (port 1-65535)';
      expect(await single(':tunnel 0'), portUsage);
      expect(await single(':tunnel 70000'), portUsage);
      expect(await single(':tunnel --secure'), portUsage);
    });

    test(':tunnel rejects a malformed --public-port', () async {
      expect(
        await single(':tunnel 8080 --public-port abc'),
        'tunnel: invalid --public-port value',
      );
      expect(
        await single(':tunnel 8080 --public-port'),
        'usage: :tunnel <port> [--public-port N] [--secure]',
      );
    });

    test(':tunnel close with no id prints usage', () async {
      expect(await single(':tunnel close'), 'usage: :tunnel close <id>');
    });

    test(':drive rejects an unknown subcommand', () async {
      final out = <String>[];
      await fullRegistry().handle(':drive bogus', _context(out));
      expect(out.first, 'Unknown :drive subcommand "bogus".');
    });

    test(':drive subcommands missing a mount id print usage', () async {
      expect(await single(':drive status'), 'usage: :drive status <mount-id>');
      expect(
        await single(':drive sync'),
        'usage: :drive sync <mount-id> [--push|--pull]',
      );
      expect(
        await single(':drive diff m1'),
        'usage: :drive diff <mount-id> <file-path>',
      );
      expect(
        await single(':drive conflicts'),
        'usage: :drive conflicts <mount-id> [--diff]',
      );
      expect(
        await single(':drive remount'),
        'usage: :drive remount <mount-id>',
      );
    });

    test(':drive sync rejects both --push and --pull', () async {
      expect(
        await single(':drive sync m1 --push --pull'),
        'drive: choose only one of --push / --pull',
      );
    });

    test(':drive unwatch with no watchers running reports so', () async {
      expect(
        await single(':drive unwatch'),
        'drive: no background watchers running.',
      );
    });

    test(':detach without an active session is a no-op message', () async {
      expect(await single(':detach'), 'No active session to detach.');
    });
  });
}

/// A minimal [LocalCommand] used to exercise registry behaviour.
class _StubCommand extends LocalCommand {
  _StubCommand(this.name, {this.aliases = const []});
  @override
  final String name;
  @override
  final List<String> aliases;
  @override
  String get description => 'stub';
  @override
  Future<void> run(LocalCommandContext context, List<String> args) async {}
}
