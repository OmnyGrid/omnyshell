import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// Generates a new globally-unique identifier (UUID v4).
///
/// Used for session ids and other entities when the caller does not supply
/// one. The value is a 36-character canonical UUID string.
String newId() => _uuid.v4();

/// A cryptographically secure random source, used for nonces and tokens.
final Random _secureRandom = Random.secure();

/// Returns [byteLength] cryptographically secure random bytes encoded as a
/// URL-safe, unpadded base64 string.
///
/// Used to mint connection nonces (replay protection) and per-session hijack
/// tokens. The default of 32 bytes yields 256 bits of entropy.
String newSecureToken([int byteLength = 32]) {
  final bytes = List<int>.generate(
    byteLength,
    (_) => _secureRandom.nextInt(256),
  );
  return base64UrlEncode(bytes).replaceAll('=', '');
}
