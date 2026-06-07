import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A credential presented during the authentication handshake.
///
/// The hierarchy is `sealed` so authenticators can exhaustively switch on the
/// credential kind. The Hub announces a per-connection challenge nonce in its
/// `hello`; public-key credentials must sign it, which is what makes login
/// replay-resistant on top of TLS.
@immutable
sealed class Credential {
  /// The claimed principal identifier (the login name).
  final String principal;

  /// Base constructor.
  const Credential(this.principal);
}

/// A bearer-token credential, validated against a token store. Relies on TLS
/// for secrecy in transit.
final class TokenCredential extends Credential {
  /// The opaque bearer token.
  final String token;

  /// Creates a token credential for [principal].
  const TokenCredential({required String principal, required this.token})
    : super(principal);
}

/// An Ed25519 public-key credential: the client proves possession of the
/// private key by signing the connection challenge.
final class PublicKeyCredential extends Credential {
  /// The presented public key, base64-encoded.
  final String publicKeyBase64;

  /// The Ed25519 signature over the connection challenge, base64-encoded.
  final String signatureBase64;

  /// Creates a public-key credential for [principal].
  const PublicKeyCredential({
    required String principal,
    required this.publicKeyBase64,
    required this.signatureBase64,
  }) : super(principal);

  /// The challenge bytes a verifier must check the signature against. Set by
  /// the connection handler from the per-connection nonce it issued; not sent
  /// on the wire by the client.
  static Uint8List challengeFor(String nonceBase64) =>
      Uint8List.fromList(nonceBase64.codeUnits);
}
