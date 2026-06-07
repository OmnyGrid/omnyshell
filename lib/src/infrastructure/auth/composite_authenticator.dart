import 'dart:typed_data';

import '../../domain/auth/authenticator.dart';
import '../../domain/auth/credential.dart';
import '../../domain/auth/principal.dart';
import '../../shared/errors/omnyshell_exception.dart';

/// Combines several [Authenticator]s, trying each in order until one succeeds.
///
/// Lets the Hub accept both public-key and token credentials: wrap a
/// [PublicKeyAuthenticator] and a [TokenAuthenticator]. Each delegate rejects
/// credential types it does not handle; the composite returns the first
/// success and otherwise fails closed with an [AuthException].
class CompositeAuthenticator implements Authenticator {
  final List<Authenticator> _delegates;

  /// Creates a composite over [delegates] (tried in order).
  CompositeAuthenticator(List<Authenticator> delegates)
    : _delegates = List.of(delegates);

  @override
  Future<Principal> authenticate(
    Credential credential, {
    required Uint8List challenge,
  }) async {
    AuthException? last;
    for (final delegate in _delegates) {
      try {
        return await delegate.authenticate(credential, challenge: challenge);
      } on AuthException catch (e) {
        last = e;
      }
    }
    throw last ??
        const AuthException('No authenticator accepted the credential');
  }
}
