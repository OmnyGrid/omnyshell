@TestOn('vm')
library;

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// Exercises the `:download`, `:upload` and `:drive` local commands without a
/// Hub: their help text, argument validation, and how they fail when the
/// session has no Hub connection. None of these paths reach the mount store,
/// so they never touch the user's `~/.omnyshell/mounts.json`.
void main() {
  final registry = LocalCommandRegistry.withDefaults()
    ..addFileTransferCommands();

  late List<String> out;

  setUp(() => out = []);

  /// Runs [line] in a context with no Hub connection (local mode).
  Future<void> run(String line) async {
    final handled = await registry.handle(
      line,
      LocalCommandContext(
        client: null,
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
        registry: registry,
      ),
    );
    expect(handled, isTrue, reason: '$line should be a local command');
  }

  String output() => out.join('\n');

  test(':help describes the transfer and drive commands', () async {
    await run(':help');

    expect(
      output(),
      contains(
        'Download a remote file/dir (optionally as --zip/--gz/--tar.gz)',
      ),
    );
    expect(output(), contains('Upload a local file/dir to a remote path'));
    expect(output(), contains('Manage OmnyDrive mounts on this node'));
  });

  test(':get and :put are aliases of :download and :upload', () async {
    await run(':get');
    await run(':put');

    expect(output(), contains('usage: :download <remotePath>'));
    expect(output(), contains('usage: :upload <localPath>'));
  });

  test(
    ':download --zip without a Hub connection reports the failure',
    () async {
      await run(':download /srv/app --zip');

      expect(
        output(),
        contains('Download failed: Bad state: this command requires a Hub'),
      );
    },
  );

  group(':drive', () {
    test('reports a missing Hub connection instead of throwing', () async {
      await run(':drive');

      expect(
        output(),
        contains('drive: Bad state: this command requires a Hub connection'),
      );
    });

    // Each subcommand validates its arguments before opening the mount store.
    for (final (line, usage) in [
      (':drive status', 'usage: :drive status <mount-id>'),
      (':drive sync', 'usage: :drive sync <mount-id> [--push|--pull]'),
      (':drive diff m1', 'usage: :drive diff <mount-id> <file-path>'),
      (':drive conflicts', 'usage: :drive conflicts <mount-id> [--diff]'),
      (':drive resolve', 'usage: :drive resolve <mount-id> [<file-path>]'),
      (':drive remount', 'usage: :drive remount <mount-id>'),
      (':drive unmount', 'usage: :drive unmount <mount-id> [--sync-first]'),
      (':drive watch', 'usage: :drive watch <mount-id> [--interval S]'),
    ]) {
      test('`$line` prints its usage', () async {
        await run(line);

        expect(output(), contains(usage));
      });
    }

    test('sync refuses --push together with --pull', () async {
      await run(':drive sync m1 --push --pull');

      expect(output(), contains('drive: choose only one of --push / --pull'));
    });

    test('unwatch with no watchers says so', () async {
      await run(':drive unwatch');
      await run(':drive unwatch m1');

      expect(out, [
        'drive: no background watchers running.',
        'drive: no background watchers running.',
      ]);
    });
  });
}
