@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:omnyshell/src/application/client/file_transfer.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

void main() {
  late TestCluster cluster;
  late Directory tmp;

  setUp(() async {
    cluster = await TestCluster.start();
    tmp = Directory.systemTemp.createTempSync('omnytx-it');
  });
  tearDown(() async {
    await cluster.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('downloads a file through the Hub and verifies its hash', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();

    final src = File('${tmp.path}/remote.txt')..writeAsStringSync('payload!');
    final dest = Directory('${tmp.path}/local')..createSync();

    final result = await downloadPath(
      client: client,
      nodeId: 'web-01',
      remotePath: src.path,
      localDest: dest.path,
    );

    expect(result.ok, isTrue);
    expect(File('${dest.path}/remote.txt').readAsStringSync(), 'payload!');
  });

  test('downloads to an explicit file path (rename)', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();

    final src = File('${tmp.path}/remote.txt')..writeAsStringSync('renamed!');
    final target = '${tmp.path}/out/grabbed.txt'; // parent absent, no slash

    final result = await downloadPath(
      client: client,
      nodeId: 'web-01',
      remotePath: src.path,
      localDest: target,
    );

    expect(result.ok, isTrue);
    expect(File(target).readAsStringSync(), 'renamed!');
  });

  test('uploads a directory through the Hub', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();

    final root = Directory('${tmp.path}/proj')..createSync();
    File('${root.path}/a.txt').writeAsStringSync('A');
    Directory('${root.path}/sub').createSync();
    File('${root.path}/sub/b.txt').writeAsStringSync('B');
    final remote = Directory('${tmp.path}/remote')..createSync();

    final result = await uploadPath(
      client: client,
      nodeId: 'web-01',
      localPath: root.path,
      remoteDir: remote.path,
    );

    expect(result.ok, isTrue);
    expect(File('${remote.path}/proj/a.txt').readAsStringSync(), 'A');
    expect(File('${remote.path}/proj/sub/b.txt').readAsStringSync(), 'B');
  });

  test('transfers a large file across the credit window', () async {
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();

    final rnd = Random(42);
    final bytes = Uint8List.fromList(
      List.generate(2 * 1024 * 1024, (_) => rnd.nextInt(256)),
    );
    final src = File('${tmp.path}/big.bin')..writeAsBytesSync(bytes);
    final dest = Directory('${tmp.path}/local')..createSync();

    final result = await downloadPath(
      client: client,
      nodeId: 'web-01',
      remotePath: src.path,
      localDest: dest.path,
    );

    expect(result.ok, isTrue);
    expect(File('${dest.path}/big.bin').readAsBytesSync(), bytes);
  });
}
