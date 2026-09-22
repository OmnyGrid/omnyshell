import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// Two saved sessions, the localhost one being the default.
CredentialStore _twoSessions() =>
    CredentialStore(defaultHub: 'wss://localhost:8443/shell')
      ..sessions['wss://localhost:8443/shell'] = StoredSession.token(
        principal: 'alice',
        token: '456',
      )
      ..sessions['wss://foo.example.com:8080'] = StoredSession.token(
        principal: 'joe',
        token: '123456',
      );

void main() {
  group('CredentialStore', () {
    late Directory home;

    setUp(() {
      home = Directory.systemTemp.createTempSync('omnyshell-creds-test');
    });

    tearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    test('load returns an empty store when no file exists', () async {
      final store = await CredentialStore.load(home: home.path);
      expect(store.sessions, isEmpty);
      expect(store.defaultHub, isNull);
    });

    test('save then load round-trips defaultHub and sessions', () async {
      final store = CredentialStore(defaultHub: 'wss://hub:8443');
      store.sessions['wss://hub:8443'] = StoredSession.token(
        principal: 'alice',
        token: 's3cr3t',
        ca: '/path/ca.pem',
      );
      store.sessions['wss://other:8443'] = StoredSession.publicKey(
        principal: 'bob',
        keyPath: '/home/bob/id_ed25519',
      );
      await store.save(home: home.path);

      final loaded = await CredentialStore.load(home: home.path);
      expect(loaded.defaultHub, 'wss://hub:8443');
      expect(loaded.sessions, hasLength(2));

      final alice = loaded.sessions['wss://hub:8443']!;
      expect(alice.method, 'token');
      expect(alice.token, 's3cr3t');
      expect(alice.ca, '/path/ca.pem');

      final bob = loaded.sessions['wss://other:8443']!;
      expect(bob.method, 'publicKey');
      expect(bob.keyPath, '/home/bob/id_ed25519');
      expect(bob.token, isNull);
    });

    test(
      'round-trips the insecureSkipVerify flag, defaulting to false',
      () async {
        final store = CredentialStore();
        store.sessions['wss://insecure:8443'] = StoredSession.token(
          principal: 'alice',
          token: 's3cr3t',
          insecureSkipVerify: true,
        );
        store.sessions['wss://secure:8443'] = StoredSession.token(
          principal: 'bob',
          token: 't0ken',
        );
        await store.save(home: home.path);

        final loaded = await CredentialStore.load(home: home.path);
        expect(
          loaded.sessions['wss://insecure:8443']!.insecureSkipVerify,
          isTrue,
        );
        expect(
          loaded.sessions['wss://secure:8443']!.insecureSkipVerify,
          isFalse,
        );
      },
    );

    test('insecureSkipVerify is omitted from JSON when false', () {
      final secure = StoredSession.token(principal: 'a', token: 't').toJson();
      expect(secure.containsKey('insecureSkipVerify'), isFalse);
      final insecure = StoredSession.token(
        principal: 'a',
        token: 't',
        insecureSkipVerify: true,
      ).toJson();
      expect(insecure['insecureSkipVerify'], isTrue);
    });

    test('token session builds a TokenCredentialProvider', () async {
      final provider = await StoredSession.token(
        principal: 'alice',
        token: 's3cr3t',
      ).toCredentialProvider();
      expect(provider, isA<TokenCredentialProvider>());
      expect(provider.principal, 'alice');
      final request = await provider.createAuthRequest('nonce');
      expect(request.method, 'token');
      expect(request.token, 's3cr3t');
    });

    test('key session builds a matching PublicKeyCredentialProvider', () async {
      final original = await PublicKeyCredentialProvider.generate('bob');
      final seed = await original.keyPair.extractPrivateKeyBytes();
      final keyFile = File('${home.path}/id_ed25519')
        ..writeAsStringSync(base64.encode(seed));

      final provider = await StoredSession.publicKey(
        principal: 'bob',
        keyPath: keyFile.path,
      ).toCredentialProvider();

      expect(provider, isA<PublicKeyCredentialProvider>());
      final rebuilt = provider as PublicKeyCredentialProvider;
      expect(await rebuilt.publicKeyBase64(), await original.publicKeyBase64());
    });

    test('hubs lists the saved keys sorted', () {
      final store = _twoSessions();
      expect(store.hubs, [
        'wss://foo.example.com:8080',
        'wss://localhost:8443/shell',
      ]);
    });

    test('resolveHub matches a key verbatim', () {
      expect(
        _twoSessions().resolveHub('wss://localhost:8443/shell'),
        'wss://localhost:8443/shell',
      );
    });

    test('resolveHub matches the same URL written differently', () {
      final store = _twoSessions();
      expect(
        store.resolveHub('WSS://LocalHost:8443/shell/'),
        'wss://localhost:8443/shell',
      );
      expect(
        store.resolveHub('wss://foo.example.com:8080/'),
        'wss://foo.example.com:8080',
      );
    });

    test('resolveHub matches a unique fragment of a key', () {
      final store = _twoSessions();
      expect(store.resolveHub('foo.example'), 'wss://foo.example.com:8080');
      expect(store.resolveHub('localhost:8443'), 'wss://localhost:8443/shell');
    });

    test('resolveHub returns null when nothing matches', () {
      expect(_twoSessions().resolveHub('wss://nope:1234'), isNull);
      expect(_twoSessions().resolveHub('  '), isNull);
    });

    test('resolveHub returns null when the fragment is ambiguous', () {
      final store = _twoSessions();
      store.sessions['wss://foo.example.com:9090'] = StoredSession.token(
        principal: 'joe',
        token: '1',
      );
      expect(store.resolveHub('foo.example'), isNull);
      expect(store.matchHubs('foo.example'), [
        'wss://foo.example.com:8080',
        'wss://foo.example.com:9090',
      ]);
    });

    test('selectDefaultHub adopts a saved session', () {
      final store = _twoSessions();
      expect(
        store.selectDefaultHub('foo.example'),
        'wss://foo.example.com:8080',
      );
      expect(store.defaultHub, 'wss://foo.example.com:8080');
    });

    test('selectDefaultHub leaves the default alone when unresolved', () {
      final store = _twoSessions();
      expect(store.selectDefaultHub('wss://nope:1234'), isNull);
      expect(store.defaultHub, 'wss://localhost:8443/shell');
    });

    test('saved file has mode 600 on POSIX', () async {
      if (Platform.isWindows) return;
      final store = CredentialStore()
        ..sessions['wss://hub:8443'] = StoredSession.token(
          principal: 'alice',
          token: 's3cr3t',
        );
      await store.save(home: home.path);

      final result = await Process.run('stat', [
        '-f',
        '%Lp',
        CredentialStore.path(home: home.path),
      ]);
      // Linux `stat` uses -c; fall back when -f is unsupported.
      final mode = result.exitCode == 0
          ? (result.stdout as String).trim()
          : (await Process.run('stat', [
              '-c',
              '%a',
              CredentialStore.path(home: home.path),
            ])).stdout.toString().trim();
      expect(mode, '600');
    });
  });
}
