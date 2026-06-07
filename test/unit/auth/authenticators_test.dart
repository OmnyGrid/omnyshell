import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_hub.dart';
import 'package:test/test.dart';

void main() {
  Uint8List challenge(String nonce) => Uint8List.fromList(utf8.encode(nonce));

  group('TokenAuthenticator', () {
    late TokenAuthenticator auth;

    setUp(() {
      auth = TokenAuthenticator({
        'secret': TokenGrant(
          principal: PrincipalId('alice'),
          displayName: 'Alice',
          roles: {'admin'},
        ),
      });
    });

    test('accepts a valid token and resolves roles', () async {
      final principal = await auth.authenticate(
        const TokenCredential(principal: 'alice', token: 'secret'),
        challenge: challenge('n'),
      );
      expect(principal.id.value, 'alice');
      expect(principal.hasRole('admin'), isTrue);
    });

    test('rejects an invalid token', () {
      expect(
        () => auth.authenticate(
          const TokenCredential(principal: 'alice', token: 'wrong'),
          challenge: challenge('n'),
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('rejects when token does not match the claimed principal', () {
      expect(
        () => auth.authenticate(
          const TokenCredential(principal: 'mallory', token: 'secret'),
          challenge: challenge('n'),
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('PublicKeyAuthenticator', () {
    test('verifies a signature over the challenge nonce', () async {
      final provider = await PublicKeyCredentialProvider.generate('bob');
      final store = AuthorizedKeysStore([
        AuthorizedKey(
          principal: PrincipalId('bob'),
          publicKey: Ed25519PublicKey.fromBase64(
            await provider.publicKeyBase64(),
          ),
          roles: {'developer'},
        ),
      ]);
      final auth = PublicKeyAuthenticator(store);

      const nonce = 'fixed-nonce-123';
      final request = await provider.createAuthRequest(nonce);
      final credential = PublicKeyCredential(
        principal: request.principal,
        publicKeyBase64: request.publicKey!,
        signatureBase64: request.signature!,
      );

      final principal = await auth.authenticate(
        credential,
        challenge: challenge(nonce),
      );
      expect(principal.id.value, 'bob');
      expect(principal.hasRole('developer'), isTrue);
    });

    test(
      'rejects a signature over a different nonce (replay protection)',
      () async {
        final provider = await PublicKeyCredentialProvider.generate('bob');
        final store = AuthorizedKeysStore([
          AuthorizedKey(
            principal: PrincipalId('bob'),
            publicKey: Ed25519PublicKey.fromBase64(
              await provider.publicKeyBase64(),
            ),
          ),
        ]);
        final auth = PublicKeyAuthenticator(store);
        final request = await provider.createAuthRequest('nonce-A');

        expect(
          () => auth.authenticate(
            PublicKeyCredential(
              principal: request.principal,
              publicKeyBase64: request.publicKey!,
              signatureBase64: request.signature!,
            ),
            challenge: challenge('nonce-B'),
          ),
          throwsA(isA<AuthException>()),
        );
      },
    );

    test('rejects a key that is not authorized', () async {
      final provider = await PublicKeyCredentialProvider.generate('bob');
      final auth = PublicKeyAuthenticator(AuthorizedKeysStore());
      final request = await provider.createAuthRequest('n');
      expect(
        () => auth.authenticate(
          PublicKeyCredential(
            principal: request.principal,
            publicKeyBase64: request.publicKey!,
            signatureBase64: request.signature!,
          ),
          challenge: challenge('n'),
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('AuthorizedKeysStore.parse', () {
    test('parses entries and skips comments', () {
      final key = Ed25519PublicKey.fromBytes(List<int>.filled(32, 1));
      final store = AuthorizedKeysStore.parse('''
# a comment
alice ${key.base64} admin,ci Alice Example

''');
      expect(store.entries, hasLength(1));
      final entry = store.find('alice', key);
      expect(entry, isNotNull);
      expect(entry!.roles, {'admin', 'ci'});
      expect(entry.displayName, 'Alice Example');
    });
  });

  group('CompositeAuthenticator', () {
    test(
      'falls through to the authenticator that accepts the credential',
      () async {
        final composite = CompositeAuthenticator([
          PublicKeyAuthenticator(AuthorizedKeysStore()),
          TokenAuthenticator({
            'tok': TokenGrant(principal: PrincipalId('carol')),
          }),
        ]);
        final principal = await composite.authenticate(
          const TokenCredential(principal: 'carol', token: 'tok'),
          challenge: Uint8List(0),
        );
        expect(principal.id.value, 'carol');
      },
    );
  });
}
