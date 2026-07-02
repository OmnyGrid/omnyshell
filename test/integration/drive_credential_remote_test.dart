@TestOn('vm')
library;

import 'dart:io';

import 'package:omnydrive/omnydrive.dart' show GitPat;
import 'package:omnyshell/omnyshell_hub.dart' show PrincipalId, TokenGrant;
import 'package:omnyshell/src/infrastructure/auth/node_git_credentials.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// End-to-end: a client manages its **own** git credentials on a remote node
/// over the hub (`ClientRuntime.driveCredential*` → hub relay → node handler),
/// proving the hub-stamped principal scopes every operation to the caller.
void main() {
  late TestCluster cluster;
  late Directory tmp;
  late String nodeHome;

  setUp(() async {
    cluster = await TestCluster.start(
      tokens: {
        'node-token': TokenGrant(
          principal: PrincipalId('node-account'),
          roles: {'node'},
        ),
        // Two admins so both are authorized to reach the node (drive access).
        'alice-token': TokenGrant(
          principal: PrincipalId('alice'),
          roles: {'admin'},
        ),
        'bob-token': TokenGrant(
          principal: PrincipalId('bob'),
          roles: {'admin'},
        ),
      },
    );
    tmp = Directory.systemTemp.createTempSync('omnyshell-remote-cred');
    nodeHome =
        tmp.path; // isolates the node's ~/.omnyshell/git-credentials.json
    await cluster.startNode(id: 'web-01', gitCredentialsHome: nodeHome);
  });

  tearDown(() async {
    await cluster.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('remote add/list is scoped to the caller principal', () async {
    final alice = await cluster.connectClient(
      token: 'alice-token',
      principal: 'alice',
    );
    final bob = await cluster.connectClient(
      token: 'bob-token',
      principal: 'bob',
    );

    final add = await alice.driveCredentialAdd(
      nodeId: 'web-01',
      host: 'github.com',
      credential: GitPat(token: 'ALICE-TOKEN').toJson(),
    );
    expect(add.ok, isTrue, reason: add.message);

    final aliceList = await alice.driveCredentialList(nodeId: 'web-01');
    expect(aliceList.ok, isTrue);
    expect(aliceList.entries.map((e) => e.host), contains('github.com'));
    expect(aliceList.entries.single.description, contains('***')); // masked

    // bob sees none of alice's credentials.
    final bobList = await bob.driveCredentialList(nodeId: 'web-01');
    expect(bobList.entries, isEmpty);

    // On disk: stored under alice only — never global, never bob.
    final stored = await NodeGitCredentials.load(home: nodeHome);
    expect(stored.storeFor('alice')!.get('github.com'), isA<GitPat>());
    expect(stored.global.hosts, isEmpty);
    expect(stored.storeFor('bob'), isNull);
  });

  test('remove only affects the caller principal', () async {
    final alice = await cluster.connectClient(
      token: 'alice-token',
      principal: 'alice',
    );
    final bob = await cluster.connectClient(
      token: 'bob-token',
      principal: 'bob',
    );
    await alice.driveCredentialAdd(
      nodeId: 'web-01',
      host: 'github.com',
      credential: GitPat(token: 'A').toJson(),
    );
    await bob.driveCredentialAdd(
      nodeId: 'web-01',
      host: 'github.com',
      credential: GitPat(token: 'B').toJson(),
    );

    final rm = await alice.driveCredentialRemove(
      nodeId: 'web-01',
      host: 'github.com',
    );
    expect(rm.ok, isTrue, reason: rm.message);
    expect(
      (await alice.driveCredentialList(nodeId: 'web-01')).entries,
      isEmpty,
    );

    // bob's credential is untouched.
    final bobList = await bob.driveCredentialList(nodeId: 'web-01');
    expect(bobList.entries.map((e) => e.host), contains('github.com'));
  });
}
