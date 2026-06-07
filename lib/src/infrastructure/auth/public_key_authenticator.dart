import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/auth/authenticator.dart';
import '../../domain/auth/credential.dart';
import '../../domain/auth/principal.dart';
import '../../domain/value_objects/principal_id.dart';
import '../../domain/value_objects/public_key.dart';
import '../../shared/errors/omnyshell_exception.dart';
import 'authorized_keys_store.dart';

/// Authenticates [PublicKeyCredential]s against an [AuthorizedKeysStore].
///
/// The principal proves possession of its private key by signing the
/// per-connection challenge nonce; the signature is verified with Ed25519 and
/// the `(principal, publicKey)` pair must be present in the store. Because the
/// nonce is single-use, a captured signature cannot be replayed onto a new
/// connection.
class PublicKeyAuthenticator implements Authenticator {
  /// The trust store of authorized public keys.
  final AuthorizedKeysStore store;

  final Ed25519 _algorithm = Ed25519();

  /// Creates a public-key authenticator backed by [store].
  PublicKeyAuthenticator(this.store);

  @override
  Future<Principal> authenticate(
    Credential credential, {
    required Uint8List challenge,
  }) async {
    if (credential is! PublicKeyCredential) {
      throw const AuthException('Unsupported credential for public-key auth');
    }

    final Ed25519PublicKey publicKey;
    try {
      publicKey = Ed25519PublicKey.fromBase64(credential.publicKeyBase64);
    } on Object {
      throw const AuthException('Malformed public key');
    }

    final entry = store.find(credential.principal, publicKey);
    if (entry == null) {
      throw const AuthException('Public key not authorized for principal');
    }

    final List<int> signatureBytes;
    try {
      signatureBytes = base64.decode(
        base64.normalize(_toStandard(credential.signatureBase64)),
      );
    } on Object {
      throw const AuthException('Malformed signature');
    }

    final valid = await _algorithm.verify(
      challenge,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKey.bytes, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const AuthException('Signature verification failed');
    }

    return Principal(
      id: PrincipalId(credential.principal),
      displayName: entry.displayName.isEmpty
          ? credential.principal
          : entry.displayName,
      roles: entry.roles,
    );
  }

  static String _toStandard(String input) =>
      input.replaceAll('-', '+').replaceAll('_', '/');
}
