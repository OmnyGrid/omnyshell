import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

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
