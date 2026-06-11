import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

LocalCommandContext _context(List<String> out) => LocalCommandContext(
  client: ClientRuntime(
    ClientConfig(
      hubUri: Uri.parse('wss://localhost:1/'),
      credentials: const TokenCredentialProvider(
        principal: 'tester',
        token: 'tok',
      ),
    ),
  ),
  node: NodeDescriptor(
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
  startedAt: DateTime.now(),
  writeLine: out.add,
);

void main() {
  group('LocalCommandRegistry.isLocalCommand', () {
    final registry = LocalCommandRegistry.withDefaults();

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
      final registry = LocalCommandRegistry.withDefaults();

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

      final handled = await LocalCommandRegistry.withDefaults().handle(
        ':exit',
        context,
      );

      expect(handled, isTrue);
      expect(context.exitRequested, isTrue);
    });

    test('an unknown command is reported with the `:` prefix', () async {
      final out = <String>[];

      final handled = await LocalCommandRegistry.withDefaults().handle(
        ':nope',
        _context(out),
      );

      expect(handled, isTrue);
      expect(out, contains('Unknown command: :nope'));
    });

    test(':ping rejects a non-positive or non-numeric count', () async {
      for (final bad in [':ping 0', ':ping -1', ':ping abc']) {
        final out = <String>[];
        await LocalCommandRegistry.withDefaults().handle(bad, _context(out));
        expect(
          out.single,
          'usage: :ping [count] (count must be a positive integer)',
          reason: bad,
        );
      }
    });

    test(':info reports node, hub and platform fields', () async {
      final out = <String>[];
      await LocalCommandRegistry.withDefaults().handle(':info', _context(out));
      expect(out.any((l) => l.startsWith('Node: n1')), isTrue);
      expect(out.any((l) => l == 'OS: linux'), isTrue);
      expect(out.any((l) => l == 'Hub: wss://localhost:1/'), isTrue);
      // Without an open session the shell-family line is omitted, not an error.
      expect(out.any((l) => l.startsWith('Shell:')), isFalse);
      expect(out.any((l) => l.startsWith('Session Duration:')), isTrue);
    });

    test(':help lists the :tree command', () async {
      final out = <String>[];
      await LocalCommandRegistry.withDefaults().handle(':help', _context(out));
      expect(out.any((l) => l.contains(':tree')), isTrue);
    });

    test(':tree rejects a bad -L depth without touching the network', () async {
      for (final bad in [':tree -L abc', ':tree -L -1', ':tree -L']) {
        final out = <String>[];
        await LocalCommandRegistry.withDefaults().handle(bad, _context(out));
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
}
