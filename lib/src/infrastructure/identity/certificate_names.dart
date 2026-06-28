import 'dart:convert';
import 'dart:typed_data';

import 'spki.dart';

/// Extracts the DNS host name an X.509 certificate is issued for.
///
/// Used to derive the public host advertised to tunnel clients from the Hub's
/// own certificate when it is not configured explicitly. The preferred source
/// is the first `dNSName` of the Subject Alternative Name extension (OID
/// `2.5.29.17`); when absent it falls back to the subject Common Name (OID
/// `2.5.4.3`). Returns `null` for any structure it cannot parse so callers can
/// fall back to their previous default.
class CertificateNames {
  const CertificateNames._();

  // OID content bytes (the value after the `06 len` TLV header).
  static const List<int> _oidCommonName = [0x55, 0x04, 0x03]; // 2.5.4.3
  static const List<int> _oidSubjectAltName = [0x55, 0x1d, 0x11]; // 2.5.29.17

  /// Returns the certificate's primary DNS name, or `null` when it cannot be
  /// determined. Accepts PEM or DER [certBytes].
  static String? primaryDnsName(Uint8List certBytes) {
    try {
      final der = CertificateIdentity.pemToDer(certBytes) ?? certBytes;
      final cert = _read(der, 0);
      if (cert.tag != 0x30) return null;
      final tbs = _read(der, cert.contentStart);
      if (tbs.tag != 0x30) return null;
      return _sanDnsName(der, tbs) ?? _subjectCommonName(der, tbs);
    } on Object {
      return null;
    }
  }

  /// The first `dNSName` ([2] IA5String) of the SAN extension, if present.
  static String? _sanDnsName(Uint8List der, _Tlv tbs) {
    // Extensions live in the [3] EXPLICIT context wrapper inside tbsCertificate.
    final wrapper = _firstChild(der, tbs, (t) => t.tag == 0xa3);
    if (wrapper == null) return null;
    final extensions = _read(der, wrapper.contentStart);
    if (extensions.tag != 0x30) return null;

    for (final ext in _children(der, extensions)) {
      if (ext.tag != 0x30) continue; // Extension ::= SEQUENCE
      final oid = _read(der, ext.contentStart);
      if (oid.tag != 0x06) continue;
      if (!_oidEquals(der, oid, _oidSubjectAltName)) continue;
      // extnValue is the trailing OCTET STRING (an optional critical BOOLEAN may
      // sit between the OID and it).
      _Tlv? extnValue;
      var off = oid.contentEnd;
      while (off < ext.contentEnd) {
        final el = _read(der, off);
        if (el.tag == 0x04) extnValue = el;
        off = el.contentEnd;
      }
      if (extnValue == null) return null;
      final names = _read(der, extnValue.contentStart); // GeneralNames SEQUENCE
      if (names.tag != 0x30) return null;
      for (final gn in _children(der, names)) {
        if (gn.tag == 0x82) {
          // dNSName: context [2] primitive, IA5String content.
          return ascii.decode(
            Uint8List.sublistView(der, gn.contentStart, gn.contentEnd),
            allowInvalid: true,
          );
        }
      }
      return null;
    }
    return null;
  }

  /// The subject Common Name attribute value, if present.
  static String? _subjectCommonName(Uint8List der, _Tlv tbs) {
    // tbsCertificate SEQUENCEs in order: 1=signature, 2=issuer, 3=validity,
    // 4=subject. The subject is an RDNSequence (SEQUENCE OF SET OF
    // AttributeTypeAndValue).
    var seqCount = 0;
    _Tlv? subject;
    for (final el in _children(der, tbs)) {
      if (el.tag != 0x30) continue;
      if (++seqCount == 4) {
        subject = el;
        break;
      }
    }
    if (subject == null) return null;

    for (final rdn in _children(der, subject)) {
      if (rdn.tag != 0x31) continue; // SET
      for (final atv in _children(der, rdn)) {
        if (atv.tag != 0x30) continue; // SEQUENCE { type, value }
        final oid = _read(der, atv.contentStart);
        if (oid.tag != 0x06 || !_oidEquals(der, oid, _oidCommonName)) continue;
        final value = _read(der, oid.contentEnd);
        return utf8.decode(
          Uint8List.sublistView(der, value.contentStart, value.contentEnd),
          allowMalformed: true,
        );
      }
    }
    return null;
  }

  /// The direct TLV children contained within [parent]'s content.
  static Iterable<_Tlv> _children(Uint8List der, _Tlv parent) sync* {
    var off = parent.contentStart;
    while (off < parent.contentEnd) {
      final el = _read(der, off);
      yield el;
      off = el.contentEnd;
    }
  }

  /// The first direct child of [parent] matching [test], or `null`.
  static _Tlv? _firstChild(
    Uint8List der,
    _Tlv parent,
    bool Function(_Tlv) test,
  ) {
    for (final el in _children(der, parent)) {
      if (test(el)) return el;
    }
    return null;
  }

  static bool _oidEquals(Uint8List der, _Tlv oid, List<int> content) {
    if (oid.contentEnd - oid.contentStart != content.length) return false;
    for (var i = 0; i < content.length; i++) {
      if (der[oid.contentStart + i] != content[i]) return false;
    }
    return true;
  }

  /// Reads a single DER tag-length-value triple starting at [start].
  static _Tlv _read(Uint8List data, int start) {
    var i = start;
    if (i >= data.length) throw const FormatException('truncated tag');
    final tag = data[i++];
    if (i >= data.length) throw const FormatException('truncated length');
    var length = data[i++];
    if (length & 0x80 != 0) {
      final numBytes = length & 0x7f;
      if (numBytes < 1 || numBytes > 4) {
        throw const FormatException('unsupported length');
      }
      length = 0;
      for (var b = 0; b < numBytes; b++) {
        if (i >= data.length) throw const FormatException('truncated length');
        length = (length << 8) | data[i++];
      }
    }
    final contentStart = i;
    final contentEnd = contentStart + length;
    if (contentEnd > data.length) {
      throw const FormatException('content exceeds buffer');
    }
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
