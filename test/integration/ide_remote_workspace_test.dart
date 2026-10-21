@TestOn('vm')
@Tags(['windows'])
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_node.dart';
import 'package:omnyshell/src/application/client/ide/workspace/remote_workspace.dart';
import 'package:omnyshell/src/application/client/ide/workspace/workspace.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// The `:ide` workspace against a real node, over a real Hub, on whatever
/// this machine is: on Windows (tagged `windows`, so the Windows CI job runs
/// it) through PowerShell — the shell family a Windows node's session reports
/// — and elsewhere through the POSIX commands. Every file operation the IDE
/// performs, including the awkward inputs: non-ASCII names and content, a
/// quote and spaces in a path, a file large enough to need several writes,
/// and failures reported as such.
void main() {
  final windows = Platform.isWindows;
  late TestCluster cluster;
  late ClientRuntime client;
  late Directory dir;
  late RemoteWorkspace ws;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('omny_ide_ws');
    addTearDown(() async {
      for (var i = 0; i < 10; i++) {
        try {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    });
    cluster = await TestCluster.start();
    addTearDown(cluster.dispose);
    await cluster.startNode(
      id: 'ws-node',
      labels: {'allow-roles': 'developer'},
      backend: ProcessShellBackend(),
    );
    client = await cluster.connectClient(token: 'dev-token', principal: 'dev');
    ws = RemoteWorkspace(
      client: client,
      nodeId: 'ws-node',
      rootPath: dir.path,
      // What the node's interactive session reports on each platform.
      shellFamily: windows ? ShellFamily.powershell : ShellFamily.posix,
    );
  });

  String at(String name) => '${ws.rootPath}/$name';

  test('the root uses `/` separators on Windows', () {
    expect(ws.rootPath.contains(r'\'), isFalse);
    expect(Directory(ws.rootPath).existsSync(), isTrue);
  });

  test('lists files and directories, dot-entries included', () async {
    File('${dir.path}/a.txt').writeAsStringSync('a');
    File('${dir.path}/.hidden').writeAsStringSync('h');
    Directory('${dir.path}/sub').createSync();
    final entries = await ws.list(ws.rootPath);
    final byName = {for (final e in entries) e.name: e.isDir};
    expect(byName, {'a.txt': false, '.hidden': false, 'sub': true});
  });

  test('lists non-ASCII names intact', () async {
    File('${dir.path}/ação ✓.txt').writeAsStringSync('x');
    final entries = await ws.list(ws.rootPath);
    expect(entries.map((e) => e.name), contains('ação ✓.txt'));
  });

  test('creates a file, with missing parent directories', () async {
    final path = at('new/deep/file.txt');
    await ws.createFile(path);
    expect(File('${dir.path}/new/deep/file.txt').existsSync(), isTrue);
    expect(await ws.exists(path), isTrue);
    expect(await ws.isDirectory(path), isFalse);
    // Creating it again (touch) keeps its content.
    File('${dir.path}/new/deep/file.txt').writeAsStringSync('kept');
    await ws.createFile(path);
    expect(File('${dir.path}/new/deep/file.txt').readAsStringSync(), 'kept');
  });

  test('creates a directory', () async {
    await ws.createDirectory(at('made/inner'));
    expect(Directory('${dir.path}/made/inner').existsSync(), isTrue);
    expect(await ws.isDirectory(at('made/inner')), isTrue);
  });

  test('writes and reads back non-ASCII text', () async {
    const text = 'olá — ação ✓\n日本語\r\nend';
    await ws.write(at('text.txt'), text);
    expect(File('${dir.path}/text.txt').readAsStringSync(), text);
    expect(await ws.read(at('text.txt')), text);
  });

  test('writes a file large enough to need several commands', () async {
    final text = List.generate(4000, (i) => 'line $i — ✓').join('\n');
    await ws.write(at('big.txt'), text);
    expect(File('${dir.path}/big.txt').readAsStringSync(), text);
    // Overwriting with less truncates.
    await ws.write(at('big.txt'), 'short');
    expect(File('${dir.path}/big.txt').readAsStringSync(), 'short');
  });

  test('writes an empty file', () async {
    await ws.write(at('empty.txt'), '');
    expect(File('${dir.path}/empty.txt').lengthSync(), 0);
    expect(await ws.read(at('empty.txt')), '');
  });

  test('a quote and spaces in a path are taken literally', () async {
    final path = at("it's [a] dir/my file.txt");
    await ws.createFile(path);
    await ws.write(path, 'q');
    expect(await ws.read(path), 'q');
    final entries = await ws.list(at("it's [a] dir"));
    expect(entries.single.name, 'my file.txt');
  });

  test('missing paths: false, and failures reported', () async {
    expect(await ws.exists(at('nope')), isFalse);
    expect(await ws.isDirectory(at('nope')), isFalse);
    await expectLater(
      ws.read(at('nope.txt')),
      throwsA(isA<WorkspaceException>()),
    );
    await expectLater(
      ws.list(at('no-such-dir')),
      throwsA(isA<WorkspaceException>()),
    );
  });

  test('exec runs in the root', () async {
    File('${dir.path}/marker.txt').writeAsStringSync('m');
    final r = await ws.exec(windows ? 'Get-ChildItem -Name' : 'ls');
    expect(r.ok, isTrue, reason: r.stderr);
    expect(r.stdout, contains('marker.txt'));
  });
}
