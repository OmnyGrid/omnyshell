@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Drives the CLI's `:download`, `:upload` and `:drive` local commands against
/// a real Hub + node, which is the only way to exercise them: they open their
/// own transfer connection from the context's client config.
void main() {
  late TestCluster cluster;
  late ClientRuntime client;
  late Directory tmp;
  late List<String> out;

  setUp(() async {
    cluster = await TestCluster.start();
    await cluster.startNode(id: 'web-01');
    client = await cluster.connectClient();
    tmp = Directory.systemTemp.createTempSync('omnyshell-ftc-');
    out = [];
  });

  tearDown(() async {
    await cluster.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  final registry = LocalCommandRegistry.withDefaults()
    ..addFileTransferCommands();

  /// Runs [line] as a local command with a context wired to the live cluster.
  /// [answer] stands in for the user at the confirmation prompt; without one
  /// the context reports no way to prompt and the transfer proceeds.
  Future<void> run(String line, {String? answer, String? remoteCwd}) async {
    final handled = await registry.handle(
      line,
      LocalCommandContext(
        client: client,
        node: NodeDescriptor(
          id: NodeId('web-01'),
          displayName: 'web-01',
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
        readLine: answer == null ? null : (_) async => answer,
        currentRemoteCwd: remoteCwd == null ? null : () => remoteCwd,
      ),
    );
    expect(handled, isTrue, reason: '$line should be a local command');
  }

  /// The whole captured output as one string, for `contains` assertions.
  String output() => out.join('\n');

  group(':download', () {
    test('prints usage when given no path', () async {
      await run(':download');

      expect(output(), contains('usage: :download <remotePath>'));
    });

    test('prints usage for a flag it does not know', () async {
      await run(':download /tmp/x --bz2');

      expect(output(), contains('usage: :download <remotePath>'));
    });

    test('copies a remote file into a local directory', () async {
      final src = File('${tmp.path}/remote.txt')..writeAsStringSync('payload!');
      final dest = Directory('${tmp.path}/local')..createSync();

      await run(':download ${src.path} ${dest.path}/');

      expect(File('${dest.path}/remote.txt').readAsStringSync(), 'payload!');
      expect(output(), contains('Download: ${src.path}'));
      expect(output(), contains('Downloaded 1 file(s); all hashes verified.'));
    });

    test('resolves a relative path against the remote cwd', () async {
      File('${tmp.path}/rel.txt').writeAsStringSync('relative!');
      final dest = Directory('${tmp.path}/local')..createSync();

      await run(':download rel.txt ${dest.path}/', remoteCwd: tmp.path);

      expect(File('${dest.path}/rel.txt').readAsStringSync(), 'relative!');
    });

    test('asks before transferring, and honours a refusal', () async {
      final src = File('${tmp.path}/remote.txt')..writeAsStringSync('payload!');
      final dest = Directory('${tmp.path}/local')..createSync();

      await run(':download ${src.path} ${dest.path}/', answer: 'n');

      expect(output(), contains('Destination:'));
      expect(output(), contains('1 file(s)'));
      expect(output(), contains('[new]'));
      expect(output(), contains('Cancelled.'));
      expect(File('${dest.path}/remote.txt').existsSync(), isFalse);
    });

    test('transfers when the user accepts, flagging an overwrite', () async {
      final src = File('${tmp.path}/remote.txt')..writeAsStringSync('payload!');
      final dest = Directory('${tmp.path}/local')..createSync();
      File('${dest.path}/remote.txt').writeAsStringSync('payload!');

      await run(':download ${src.path} ${dest.path}/', answer: 'y');

      expect(output(), contains('[overwrite]'));
      expect(output(), contains('existing file(s) will be replaced'));
      expect(output(), contains('Downloaded'));
    });

    test('reports a remote path that is not there', () async {
      await run(':download ${tmp.path}/absent.txt ${tmp.path}/');

      expect(output(), contains('Download failed:'));
    });

    test('compresses a directory on the node with --tar.gz', () async {
      final dir = Directory('${tmp.path}/proj')..createSync();
      File('${dir.path}/a.txt').writeAsStringSync('A');
      final dest = Directory('${tmp.path}/local')..createSync();

      await run(':download ${dir.path} ${dest.path}/ --tar.gz');

      expect(output(), contains('Compressing ${dir.path} as .tar.gz'));
      expect(output(), contains('Saved archive:'));
      final archive = File('${dest.path}/proj.tar.gz');
      expect(archive.existsSync(), isTrue);
      expect(archive.lengthSync(), greaterThan(0));
    });

    test('names the archive itself when given an explicit target', () async {
      final src = File('${tmp.path}/remote.txt')..writeAsStringSync('payload!');

      await run(':download ${src.path} ${tmp.path}/named.gz --gz');

      expect(File('${tmp.path}/named.gz').existsSync(), isTrue);
    });

    test('refuses to gzip a directory', () async {
      final dir = Directory('${tmp.path}/proj')..createSync();

      await run(':download ${dir.path} --gz');

      expect(
        output(),
        contains('gzip cannot archive a directory; use --tar.gz or --zip'),
      );
    });

    test('refuses to tar.gz a single file', () async {
      final src = File('${tmp.path}/remote.txt')..writeAsStringSync('x');

      await run(':download ${src.path} --tar.gz');

      expect(output(), contains('use --gz or --zip for a single file'));
    });

    test('reports a missing remote path before compressing', () async {
      await run(':download ${tmp.path}/absent.txt --gz');

      expect(
        output(),
        contains('No such remote file or directory: ${tmp.path}/absent.txt'),
      );
    });
  });

  group(':upload', () {
    test('prints usage when given no path', () async {
      await run(':upload');

      expect(output(), contains('usage: :upload <localPath>'));
    });

    test('reports a local path that is not there', () async {
      await run(':upload ${tmp.path}/absent.txt');

      expect(
        output(),
        contains('No such local file or directory: ${tmp.path}/absent.txt'),
      );
    });

    test('sends a file to a remote directory', () async {
      final src = File('${tmp.path}/local.txt')..writeAsStringSync('up!');
      final dest = Directory('${tmp.path}/remote')..createSync();

      await run(':upload ${src.path} ${dest.path}/');

      expect(File('${dest.path}/local.txt').readAsStringSync(), 'up!');
      expect(output(), contains('Uploaded 1 file(s); all hashes verified.'));
    });

    test('sends a directory, and can be refused at the prompt', () async {
      final root = Directory('${tmp.path}/proj')..createSync();
      File('${root.path}/a.txt').writeAsStringSync('A');
      final dest = Directory('${tmp.path}/remote')..createSync();

      await run(':upload ${root.path} ${dest.path}/', answer: 'no');

      expect(output(), contains('Cancelled.'));
      expect(Directory('${dest.path}/proj').existsSync(), isFalse);
    });
  });

  group(':drive', () {
    test('explains an unknown subcommand and shows the usage', () async {
      await run(':drive frobnicate');

      expect(output(), contains('Unknown :drive subcommand "frobnicate"'));
      expect(output(), contains(':drive ls'));
    });

    test('mount needs both a local directory and a remote path', () async {
      await run(':drive mount only-one-arg');

      expect(output(), contains('usage:'));
    });
  });
}
