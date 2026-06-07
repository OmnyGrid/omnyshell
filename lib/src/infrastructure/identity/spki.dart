import 'dart:convert';
import 'dart:typed_data';

/// Extracts a stable public-key identity from an X.509 certificate.
///
/// The preferred output is the DER-encoded `SubjectPublicKeyInfo` (SPKI) — the
/// same field TLS certificate pinning uses — so a hub keeps the same identity
/// across certificate renewals as long as the keypair is reused. If the
/// certificate cannot be parsed (unexpected structure), callers should fall back
/// to hashing the whole certificate DER.
class CertificateIdentity {
  const CertificateIdentity._();

  /// Returns the DER `SubjectPublicKeyInfo` bytes from a PEM or DER certificate,
  /// or `null` if it cannot be located.
  static Uint8List? spkiFromCertificate(Uint8List certBytes) {
    try {
      final der = _isPem(certBytes) ? pemToDer(certBytes) : certBytes;
      if (der == null) return null;
      return _extractSpki(der);
    } on Object {
      return null;
    }
  }

  /// Decodes the first `CERTIFICATE` block of a PEM document to DER bytes, or
  /// `null` if none is present.
  static Uint8List? pemToDer(Uint8List pemBytes) {
    final text = utf8.decode(pemBytes, allowMalformed: true);
    final match = RegExp(
      '-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----',
      dotAll: true,
    ).firstMatch(text);
    if (match == null) return null;
    final body = match.group(1)!.replaceAll(RegExp(r'\s'), '');
    return Uint8List.fromList(base64.decode(body));
  }

  static bool _isPem(Uint8List bytes) {
    // PEM starts with the ASCII '-----'.
    if (bytes.length < 5) return false;
    for (var i = 0; i < 5; i++) {
      if (bytes[i] != 0x2d) return false; // '-'
    }
    return true;
  }

  /// Walks the DER `Certificate -> tbsCertificate` and returns the 5th
  /// SEQUENCE (the `subjectPublicKeyInfo`) as its full TLV bytes.
  static Uint8List _extractSpki(Uint8List der) {
    final cert = _readTlv(der, 0);
    _expect(cert.tag == 0x30, 'certificate is not a SEQUENCE');
    final tbs = _readTlv(der, cert.contentStart);
    _expect(tbs.tag == 0x30, 'tbsCertificate is not a SEQUENCE');

    // Within tbsCertificate the SEQUENCEs appear in order:
    //   1=signature, 2=issuer, 3=validity, 4=subject, 5=subjectPublicKeyInfo.
    var offset = tbs.contentStart;
    var seqCount = 0;
    while (offset < tbs.contentEnd) {
      final el = _readTlv(der, offset);
      if (el.tag == 0x30) {
        seqCount++;
        if (seqCount == 5) {
          return Uint8List.sublistView(der, el.start, el.contentEnd);
        }
      }
      offset = el.contentEnd;
    }
    throw const FormatException('subjectPublicKeyInfo not found');
  }

  static void _expect(bool condition, String message) {
    if (!condition) throw FormatException(message);
  }

  static _Tlv _readTlv(Uint8List data, int start) {
    var i = start;
    _expect(i < data.length, 'truncated tag');
    final tag = data[i++];
    _expect(i < data.length, 'truncated length');
    var length = data[i++];
    if (length & 0x80 != 0) {
      final numBytes = length & 0x7f;
      _expect(numBytes >= 1 && numBytes <= 4, 'unsupported length');
      length = 0;
      for (var b = 0; b < numBytes; b++) {
        _expect(i < data.length, 'truncated long length');
        length = (length << 8) | data[i++];
      }
    }
    final contentStart = i;
    final contentEnd = contentStart + length;
    _expect(contentEnd <= data.length, 'content exceeds buffer');
    return _Tlv(tag, start, contentStart, contentEnd);
  }
}

class _Tlv {
  final int tag;
  final int start;
  final int contentStart;
  final int contentEnd;
  const _Tlv(this.tag, this.start, this.contentStart, this.contentEnd);
}
