import 'dart:typed_data';

import 'credential.dart';
import 'principal.dart';

/// Validates a [Credential] and resolves it to a [Principal].
///
/// Implementations are pluggable (`PublicKeyAuthenticator`,
/// `TokenAuthenticator`, or a composite). The Hub never ships an allow-all
/// authenticator in its default composition root — authentication always fails
/// closed.
abstract class Authenticator {
  /// Authenticates [credential], returning the resolved [Principal].
  ///
  /// [challenge] is the per-connection nonce the Hub issued in its `hello`;
  /// public-key authenticators verify the signature against it for replay
  /// protection, while token authenticators ignore it.
  ///
  /// Throws [AuthException] if the credential is unsupported, malformed,
  /// unknown or fails verification.
  Future<Principal> authenticate(
    Credential credential, {
    required Uint8List challenge,
  });
}
