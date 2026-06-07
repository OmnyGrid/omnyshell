import 'dart:convert' as convert;
import 'dart:typed_data';

import '../../shared/errors/omnyshell_exception.dart';

/// An Ed25519 public key, used to identify users and nodes in an
/// `authorized_keys`-style trust store. Equality is by key bytes.
///
/// The value object holds only the raw key material and its canonical base64
/// encoding; signature verification lives in the infrastructure auth layer so
/// the domain stays free of crypto dependencies.
class Ed25519PublicKey {
  /// The 32 raw key bytes.
  final Uint8List bytes;

  /// The canonical (standard, unpadded) base64 encoding of [bytes].
  final String base64;

  Ed25519PublicKey._(this.bytes, this.base64);

  /// Parses a public key from its base64 [encoded] form.
  ///
  /// Accepts padded or unpadded, standard or URL-safe base64. Throws
  /// [ProtocolException] if the input is not valid base64 of a 32-byte key.
  factory Ed25519PublicKey.fromBase64(String encoded) {
    final normalized = encoded.trim();
    final Uint8List raw;
    try {
      raw = convert.base64.decode(
        convert.base64.normalize(_toStandard(normalized)),
      );
    } on FormatException {
      throw ProtocolException('Invalid base64 public key: "$encoded"');
    }
    return Ed25519PublicKey.fromBytes(raw);
  }

  /// Wraps the 32 raw key [bytes].
  ///
  /// Throws [ProtocolException] if [bytes] is not exactly 32 bytes long.
  factory Ed25519PublicKey.fromBytes(List<int> bytes) {
    if (bytes.length != 32) {
      throw ProtocolException(
        'Ed25519 public key must be 32 bytes, got ${bytes.length}',
      );
    }
    final copy = Uint8List.fromList(bytes);
    return Ed25519PublicKey._(
      copy,
      convert.base64.encode(copy).replaceAll('=', ''),
    );
  }

  static String _toStandard(String input) =>
      input.replaceAll('-', '+').replaceAll('_', '/');

  @override
  bool operator ==(Object other) =>
      other is Ed25519PublicKey && other.base64 == base64;

  @override
  int get hashCode => base64.hashCode;

  @override
  String toString() => 'Ed25519PublicKey($base64)';
}
