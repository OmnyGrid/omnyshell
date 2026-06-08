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
      expect(out.first, 'Local commands:');
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
  });
}
