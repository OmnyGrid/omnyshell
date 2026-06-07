import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/value_objects/omny_uid.dart';

/// Computes deterministic [OmnyUid]s from identity material.
///
/// Inputs are combined with a length-prefixed (TLV) framing so field boundaries
/// are unambiguous — `["ab","c"]` can never hash to the same value as
/// `["a","bc"]` — then hashed with SHA-256 and rendered as URL-safe base64. A
/// per-kind domain-separation tag prevents a node and a hub built from the same
/// bytes from colliding, and lets the scheme be versioned.
class UidComputer {
  const UidComputer._();

  static const String _nodeTag = 'omnyshell:node:v1';
  static const String _hubTag = 'omnyshell:hub:v1';

  /// Computes a node UID from its (optional) public key plus stable hardware and
  /// platform attributes. [publicKey] is empty for token/keyless nodes.
  static OmnyUid computeNodeUid({
    Uint8List? publicKey,
    required String machineId,
    required String os,
    required String arch,
    required String hostname,
  }) {
    final digest = _digest(_nodeTag, [
      publicKey ?? Uint8List(0),
      utf8.encode(machineId),
      utf8.encode(os),
      utf8.encode(arch),
      utf8.encode(hostname),
    ]);
    return OmnyUid('${OmnyUid.nodePrefix}${_encode(digest)}');
  }

  /// Computes a hub UID from its TLS public-key material (SPKI or full cert DER)
  /// plus stable hardware and platform attributes.
  static OmnyUid computeHubUid({
    required Uint8List keyMaterial,
    required String machineId,
    required String os,
    required String arch,
    required String hostname,
  }) {
    final digest = _digest(_hubTag, [
      keyMaterial,
      utf8.encode(machineId),
      utf8.encode(os),
      utf8.encode(arch),
      utf8.encode(hostname),
    ]);
    return OmnyUid('${OmnyUid.hubPrefix}${_encode(digest)}');
  }

  static List<int> _digest(String tag, List<List<int>> parts) {
    final builder = BytesBuilder(copy: false);
    _appendField(builder, utf8.encode(tag));
    for (final part in parts) {
      _appendField(builder, part);
    }
    return Sha256().toSync().hashSync(builder.takeBytes()).bytes;
  }

  static void _appendField(BytesBuilder builder, List<int> bytes) {
    final length = ByteData(4)..setUint32(0, bytes.length);
    builder.add(length.buffer.asUint8List());
    builder.add(bytes);
  }

  static String _encode(List<int> digest) =>
      base64Url.encode(digest).replaceAll('=', '');
}
