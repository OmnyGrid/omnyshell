@TestOn('!windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Drives the real `omnyshell hub info` command as a child process against a
/// live [TestCluster], with an isolated `OMNYSHELL_HOME`.
void main() {
  late Directory tmp;
  late String snapshot;
  late TestCluster cluster;

  const ca = 'test/support/certs/localhost.crt';

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('omnyshell-hub-info-cli');
    snapshot = '${tmp.path}/omnyshell.dill';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'bin/omnyshell.dart',
      '-o',
      snapshot,
    ]);
    expect(compiled.exitCode, 0, reason: compiled.stderr.toString());
    cluster = await TestCluster.start();
  });

  tearDownAll(() async {
    await cluster.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<ProcessResult> hubInfo([List<String> extra = const []]) => Process.run(
    Platform.resolvedExecutable,
    [
      snapshot,
      'hub',
      'info',
      '--hub',
      cluster.hubUri.toString(),
      '--principal',
      'alice',
      '--token',
      'admin-token',
      '--ca',
      ca,
      ...extra,
    ],
    environment: {'OMNYSHELL_HOME': tmp.path},
  );

  test('prints the Hub description in sections', () async {
    final r = await hubInfo();
    expect(r.exitCode, 0, reason: r.stderr.toString());
    final out = r.stdout as String;
    expect(
      const LineSplitter().convert(out),
      containsAllInOrder([
        'Identity',
        'System',
        'OmnyShell',
        'Activity',
        'Features',
      ]),
    );
    expect(out, contains(cluster.hubUri.toString()));
    expect(out, contains('Signed in as  Alice'));
    expect(out, contains('$omnyShellVersion (same as this client)'));
    expect(out, contains(Platform.localHostname));
  });

  test('--json prints only the record on stdout', () async {
    final r = await hubInfo(['--json']);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    final info = HubInfo.fromJson(
      (jsonDecode(r.stdout as String) as Map).cast<String, dynamic>(),
    );
    expect(info.version, omnyShellVersion);
    expect(info.platform.os, Platform.operatingSystem);
    expect(info.clients, greaterThanOrEqualTo(1));
  });

  test('a rejected token fails with a non-zero exit', () async {
    final r = await Process.run(
      Platform.resolvedExecutable,
      [
        snapshot,
        'hub',
        'info',
        '--hub',
        cluster.hubUri.toString(),
        '--principal',
        'alice',
        '--token',
        'wrong',
        '--ca',
        ca,
      ],
      environment: {'OMNYSHELL_HOME': tmp.path},
    );
    expect(r.exitCode, isNot(0));
    expect(r.stdout, isNot(contains('Identity')));
  });
}
