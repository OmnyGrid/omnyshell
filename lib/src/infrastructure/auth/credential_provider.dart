import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../protocol/control_message.dart';

/// Produces the [AuthRequest] a node or client sends in response to the Hub's
/// challenge `hello`.
///
/// Implementations encapsulate how the peer proves its identity (a bearer token
/// or an Ed25519 signature over the connection nonce), so the runtimes stay
/// independent of the credential type.
abstract class CredentialProvider {
  /// The principal (login name) this provider authenticates as.
  String get principal;

  /// Builds an [AuthRequest] answering the challenge [nonce].
  Future<AuthRequest> createAuthRequest(String nonce);

  /// The raw public-key bytes that cryptographically bind this identity, used as
  /// the strongest input to the node UID. Returns `null` when the credential has
  /// no key (e.g. a bearer token), in which case the UID falls back to hardware
  /// and platform attributes alone.
  Future<Uint8List?> identityPublicKeyBytes() async => null;
}

/// A [CredentialProvider] that presents a bearer token.
class TokenCredentialProvider implements CredentialProvider {
  @override
  final String principal;

  /// The bearer token.
  final String token;

  /// Creates a token provider.
  const TokenCredentialProvider({required this.principal, required this.token});

  @override
  Future<AuthRequest> createAuthRequest(String nonce) async =>
      AuthRequest(method: 'token', principal: principal, token: token);

  @override
  Future<Uint8List?> identityPublicKeyBytes() async => null;
}

/// A [CredentialProvider] that signs the connection nonce with an Ed25519
/// private key.
class PublicKeyCredentialProvider implements CredentialProvider {
  @override
  final String principal;

  /// The Ed25519 key pair used to sign challenges.
  final SimpleKeyPair keyPair;

  final Ed25519 _algorithm = Ed25519();

  /// Creates a public-key provider over an existing [keyPair].
  PublicKeyCredentialProvider({required this.principal, required this.keyPair});

  /// Generates a fresh key pair for [principal].
  static Future<PublicKeyCredentialProvider> generate(String principal) async {
    final keyPair = await Ed25519().newKeyPair();
    return PublicKeyCredentialProvider(principal: principal, keyPair: keyPair);
  }

  /// The base64 (unpadded) public key, e.g. for an `authorized_keys` entry.
  Future<String> publicKeyBase64() async {
    final pub = await keyPair.extractPublicKey();
    return base64.encode(pub.bytes).replaceAll('=', '');
  }

  @override
  Future<Uint8List?> identityPublicKeyBytes() async {
    final pub = await keyPair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  @override
  Future<AuthRequest> createAuthRequest(String nonce) async {
    final challenge = utf8.encode(nonce);
    final signature = await _algorithm.sign(challenge, keyPair: keyPair);
    final pub = await keyPair.extractPublicKey();
    return AuthRequest(
      method: 'publicKey',
      principal: principal,
      publicKey: base64.encode(pub.bytes).replaceAll('=', ''),
      signature: base64.encode(signature.bytes).replaceAll('=', ''),
    );
  }
}
