import 'dart:typed_data';

import '../../domain/auth/authenticator.dart';
import '../../domain/auth/credential.dart';
import '../../domain/auth/principal.dart';
import '../../domain/value_objects/principal_id.dart';
import '../../shared/errors/omnyshell_exception.dart';

/// A token and the identity it grants.
class TokenGrant {
  /// The principal the token authenticates.
  final PrincipalId principal;

  /// A human-friendly display name.
  final String displayName;

  /// Roles granted on successful authentication.
  final Set<String> roles;

  /// Creates a token grant.
  TokenGrant({
    required this.principal,
    this.displayName = '',
    this.roles = const {},
  });
}

/// Authenticates [TokenCredential]s against an in-memory token store.
///
/// Tokens are matched in constant time (per candidate) to avoid leaking their
/// length/prefix through timing. Token secrecy in transit is provided by TLS.
/// The presented credential's `principal` must match the principal the token
/// was issued for.
class TokenAuthenticator implements Authenticator {
  final Map<String, TokenGrant> _tokens;

  /// Creates a token authenticator from a [tokens] map (token → grant).
  TokenAuthenticator(Map<String, TokenGrant> tokens) : _tokens = Map.of(tokens);

  /// Registers or replaces a [token] for [grant].
  void addToken(String token, TokenGrant grant) => _tokens[token] = grant;

  @override
  Future<Principal> authenticate(
    Credential credential, {
    required Uint8List challenge,
  }) async {
    if (credential is! TokenCredential) {
      throw const AuthException('Unsupported credential for token auth');
    }

    TokenGrant? matched;
    // Iterate all entries with a constant-time comparison so a wrong token does
    // not short-circuit and reveal information through timing.
    for (final entry in _tokens.entries) {
      if (_constantTimeEquals(entry.key, credential.token)) {
        matched = entry.value;
      }
    }
    if (matched == null) {
      throw const AuthException('Invalid token');
    }
    if (matched.principal.value != credential.principal) {
      throw const AuthException('Token does not match principal');
    }

    return Principal(
      id: matched.principal,
      displayName: matched.displayName.isEmpty
          ? matched.principal.value
          : matched.displayName,
      roles: matched.roles,
    );
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
