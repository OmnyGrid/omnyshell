@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnydrive/omnydrive.dart' show GitPat, GitUserPass, OriginUri;
import 'package:omnyshell/src/infrastructure/auth/node_git_credentials.dart';
import 'package:test/test.dart';

/// Covers omnyshell's node-side git credentials: the global + per-principal
/// split, principal-first resolution with global fallback, backward-compat with
/// the legacy flat file, and the on-disk contract (distinct filename, mode 600).
/// The mechanics of injecting a credential into git live in omnydrive's tests.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('omnyshell-gitcreds'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String file() => '${tmp.path}/.omnyshell/git-credentials.json';
  Future<NodeGitCredentials> load() => NodeGitCredentials.load(home: tmp.path);

  test('load returns empty when no file exists', () async {
    final creds = await load();
    expect(creds.global.hosts, isEmpty);
    expect(creds.principals, isEmpty);
  });

  test('global and per-principal credentials round-trip', () async {
    final creds = NodeGitCredentials.empty();
    creds.scopeFor().put('github.com', GitPat(token: 'global'));
    creds
        .scopeFor(principal: 'alice')
        .put('github.com', GitPat(token: 'alice'));
    creds
        .scopeFor(principal: 'bob')
        .put('gitlab.com', GitUserPass(username: 'bob', password: 'pw'));
    await creds.save(home: tmp.path);

    final reloaded = await load();
    expect(reloaded.global.hosts, ['github.com']);
    expect(reloaded.principals, ['alice', 'bob']);
    expect(reloaded.storeFor('alice')!.get('github.com'), isA<GitPat>());
    expect(reloaded.storeFor('bob')!.get('gitlab.com'), isA<GitUserPass>());
  });

  group('resolverFor (principal-first, global fallback)', () {
    late NodeGitCredentials creds;
    setUp(() {
      creds = NodeGitCredentials.empty();
      creds.scopeFor().put('github.com', GitPat(token: 'GLOBAL'));
      creds
          .scopeFor(principal: 'alice')
          .put('github.com', GitPat(token: 'ALICE'));
    });

    GitPat? patFor(String principal, String url) =>
        creds.resolverFor(principal).resolve(OriginUri(url)) as GitPat?;

    test("a principal's own credential wins over the global one", () {
      expect(patFor('alice', 'https://github.com/x/y.git')!.token, 'ALICE');
    });

    test('a principal with no host entry falls back to global', () {
      // bob has no credentials at all.
      expect(patFor('bob', 'https://github.com/x/y.git')!.token, 'GLOBAL');
    });

    test('principal B never receives principal A\'s credential', () {
      creds.scopeFor(principal: 'bob').put('gitlab.com', GitPat(token: 'BOB'));
      // bob asking about github.com must NOT get ALICE; falls back to GLOBAL.
      expect(patFor('bob', 'https://github.com/x/y.git')!.token, 'GLOBAL');
    });

    test('no credential for the host resolves to null', () {
      expect(patFor('alice', 'https://bitbucket.org/x/y.git'), isNull);
    });
  });

  test('a legacy flat file loads as the global scope', () async {
    // The format shipped before per-principal support: a bare host map.
    Directory('${tmp.path}/.omnyshell').createSync(recursive: true);
    File(file()).writeAsStringSync(
      jsonEncode({
        'credentials': {
          'github.com': {
            'kind': 'pat',
            'username': 'x-access-token',
            'token': 't',
          },
        },
      }),
    );

    final creds = await load();
    expect(creds.global.get('github.com'), isA<GitPat>());
    expect(creds.principals, isEmpty);
  });

  test('arbitrary principal strings survive as keys', () async {
    const weird = ['alice@corp.com', 'team/infra', 'ünïcode'];
    final creds = NodeGitCredentials.empty();
    for (final p in weird) {
      creds.scopeFor(principal: p).put('github.com', GitPat(token: p));
    }
    await creds.save(home: tmp.path);

    final reloaded = await load();
    expect(reloaded.principals, unorderedEquals(weird));
    for (final p in weird) {
      expect((reloaded.storeFor(p)!.get('github.com')! as GitPat).token, p);
    }
  });

  test('saving prunes an emptied principal scope', () async {
    final creds = NodeGitCredentials.empty();
    creds.scopeFor(principal: 'alice').put('github.com', GitPat(token: 't'));
    await creds.save(home: tmp.path);

    final reloaded = await load();
    expect(reloaded.storeFor('alice')!.remove('github.com'), isTrue);
    await reloaded.save(home: tmp.path);

    expect((await load()).principals, isEmpty);
  });

  test(
    'writes git-credentials.json (not the auth credentials.json), mode 600',
    () async {
      final creds = NodeGitCredentials.empty();
      creds.scopeFor().put('github.com', GitPat(token: 't'));
      await creds.save(home: tmp.path);

      expect(File(file()).existsSync(), isTrue);
      expect(
        File('${tmp.path}/.omnyshell/credentials.json').existsSync(),
        isFalse,
      );
    },
  );

  test('the store file is owner-only (0600) on POSIX', () async {
    final creds = NodeGitCredentials.empty();
    creds.scopeFor().put('github.com', GitPat(token: 't'));
    await creds.save(home: tmp.path);
    final mode = File(file()).statSync().mode & 0x1FF;
    expect(mode, 0x180); // rw------- == 0600
  }, testOn: '!windows');
}
