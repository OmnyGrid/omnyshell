import '../../domain/value_objects/principal_id.dart';
import '../../domain/value_objects/public_key.dart';

/// A single authorized identity: a principal, the public key that proves it,
/// and the roles it is granted.
class AuthorizedKey {
  /// The principal the key authenticates.
  final PrincipalId principal;

  /// The Ed25519 public key.
  final Ed25519PublicKey publicKey;

  /// A human-friendly display name.
  final String displayName;

  /// Roles granted on successful authentication.
  final Set<String> roles;

  /// Creates an authorized-key entry.
  AuthorizedKey({
    required this.principal,
    required this.publicKey,
    this.displayName = '',
    this.roles = const {},
  });
}

/// An in-memory `authorized_keys`-style trust store consulted by
/// [PublicKeyAuthenticator].
///
/// Entries can be added programmatically or parsed from a simple text format,
/// one entry per line:
///
/// ```text
/// # principal  base64-ed25519-key  role1,role2  Display Name
/// alice        AAAA...==           admin        Alice Example
/// ```
///
/// Blank lines and lines beginning with `#` are ignored.
class AuthorizedKeysStore {
  final List<AuthorizedKey> _entries;

  /// Creates a store from existing [entries].
  AuthorizedKeysStore([List<AuthorizedKey>? entries])
    : _entries = [...?entries];

  /// All entries (unmodifiable view).
  List<AuthorizedKey> get entries => List.unmodifiable(_entries);

  /// Adds an [entry] to the store.
  void add(AuthorizedKey entry) => _entries.add(entry);

  /// Returns the entry matching both [principal] and [publicKey], or `null` if
  /// the pair is not authorized.
  AuthorizedKey? find(String principal, Ed25519PublicKey publicKey) {
    for (final entry in _entries) {
      if (entry.principal.value == principal && entry.publicKey == publicKey) {
        return entry;
      }
    }
    return null;
  }

  /// Parses an [AuthorizedKeysStore] from the line-based text format.
  factory AuthorizedKeysStore.parse(String text) {
    final entries = <AuthorizedKey>[];
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final roles = parts.length >= 3
          ? parts[2]
                .split(',')
                .map((r) => r.trim())
                .where((r) => r.isNotEmpty)
                .toSet()
          : <String>{};
      entries.add(
        AuthorizedKey(
          principal: PrincipalId(parts[0]),
          publicKey: Ed25519PublicKey.fromBase64(parts[1]),
          roles: roles,
          displayName: parts.length >= 4 ? parts.sublist(3).join(' ') : '',
        ),
      );
    }
    return AuthorizedKeysStore(entries);
  }
}
