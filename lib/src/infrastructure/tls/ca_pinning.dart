import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/api.dart' show PublicKeyParameter;
import 'package:pointycastle/asymmetric/api.dart'
    show RSAPublicKey, RSASignature;
import 'package:pointycastle/digests/sha1.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha384.dart';
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

/// A pinned set of trust anchors loaded from a `--ca` PEM file, used to accept a
/// Hub's TLS certificate by **chain trust only**, deliberately ignoring the
/// hostname/SAN.
///
/// Dart's TLS stack already validates the chain when the CA is installed in a
/// [SecurityContext], but it *also* enforces hostname matching, which fails for
/// self-signed/dev hubs whose certificate only lists `localhost`/`127.0.0.1`.
/// The [SecureSocket] escape hatch — `badCertificateCallback` — is synchronous
/// and cannot tell an untrusted chain apart from a mere hostname mismatch, so a
/// blanket "accept" would re-admit arbitrary (MITM) certificates. [CaTrust]
/// closes that gap: it re-verifies, in the callback, that the presented leaf is
/// actually issued by the pinned CA (or *is* the pinned certificate) before
/// accepting — giving "verify-ca" semantics without `--insecure-skip-verify`.
///
/// Scope: single-level CA → leaf chains (as produced by `omnyshell cert gen`)
/// and RSA keys. Deeper chains or non-RSA certificates fall through to a
/// rejection, leaving the caller to use proper SANs or `--insecure-skip-verify`.
class CaTrust {
  final List<_PinnedCert> _cas;

  CaTrust._(this._cas);

  /// Loads every certificate from the PEM at [path] as a trust anchor.
  ///
  /// Throws [CaTrustException] if the file holds no parseable certificate.
  factory CaTrust.fromPemFile(String path) {
    final pem = File(path).readAsStringSync();
    final cas = <_PinnedCert>[];
    for (final der in _pemCertificates(pem)) {
      final parsed = _PinnedCert.tryParse(der);
      if (parsed != null) cas.add(parsed);
    }
    if (cas.isEmpty) {
      throw CaTrustException('no parseable certificate found in $path');
    }
    return CaTrust._(cas);
  }

  /// Whether [leaf] should be trusted: it is byte-identical to a pinned anchor,
  /// or it is within its validity window and carries a valid signature from a
  /// pinned CA whose subject matches the leaf's issuer.
  bool accepts(X509Certificate leaf) {
    final leafDer = Uint8List.fromList(leaf.der);

    // Exact pin: `--ca` is the server's own (self-signed) certificate.
    for (final ca in _cas) {
      if (_bytesEqual(ca.der, leafDer)) return true;
    }

    // Issued-by-pinned-CA: verify the leaf's signature against the CA's key.
    final now = DateTime.now();
    if (now.isBefore(leaf.startValidity) || now.isAfter(leaf.endValidity)) {
      return false;
    }
    final parsed = _LeafCert.tryParse(leafDer);
    if (parsed == null) return false;
    for (final ca in _cas) {
      if (!_bytesEqual(ca.subjectDer, parsed.issuerDer)) continue;
      if (parsed.verifiedBy(ca.publicKey)) return true;
    }
    return false;
  }
}

/// The signature of a [SecureSocket] / [HttpClient] `badCertificateCallback`.
typedef BadCertificateCallback =
    bool Function(X509Certificate cert, String host, int port);

/// Builds a `badCertificateCallback` that accepts a Hub certificate only when it
/// is trusted by the CA pinned at [caPath], ignoring the hostname. Warns once on
/// stderr when it admits a connection on that basis.
///
/// Throws [CaTrustException] / [FileSystemException] if [caPath] cannot be read
/// or parsed.
BadCertificateCallback caPinnedBadCertificateCallback(String caPath) {
  final trust = CaTrust.fromPemFile(caPath);
  var warned = false;
  return (cert, host, port) {
    if (!trust.accepts(cert)) return false;
    if (!warned) {
      warned = true;
      stderr.writeln(
        '[security] Hub certificate verified against pinned CA ($caPath); '
        'hostname not checked ($host:$port).',
      );
    }
    return true;
  };
}

/// Thrown when a `--ca` file cannot be turned into a usable trust anchor.
class CaTrustException implements Exception {
  final String message;
  const CaTrustException(this.message);

  @override
  String toString() => message;
}

/// A trust anchor: its DER, its subject Name (DER, for issuer matching) and its
/// RSA public key (for verifying certificates it signed).
class _PinnedCert {
  final Uint8List der;
  final Uint8List subjectDer;
  final RSAPublicKey publicKey;

  _PinnedCert(this.der, this.subjectDer, this.publicKey);

  static _PinnedCert? tryParse(Uint8List der) {
    try {
      final tbs = _tbsCertificate(_certificate(der));
      final base = _tbsFieldBase(tbs);
      final subject = tbs.elements[base + 4];
      final spki = tbs.elements[base + 5] as ASN1Sequence;
      return _PinnedCert(der, subject.encodedBytes, _rsaPublicKey(spki));
    } on Object {
      return null;
    }
  }
}

/// The pieces of a leaf certificate needed to verify it against a CA.
class _LeafCert {
  final Uint8List tbsDer;
  final Uint8List signature;
  final String signatureOid;
  final Uint8List issuerDer;

  _LeafCert(this.tbsDer, this.signature, this.signatureOid, this.issuerDer);

  static _LeafCert? tryParse(Uint8List der) {
    try {
      final cert = _certificate(der);
      final tbs = cert.elements[0] as ASN1Sequence;
      final sigAlg = cert.elements[1] as ASN1Sequence;
      final sigVal = cert.elements[2] as ASN1BitString;
      final base = _tbsFieldBase(tbs);
      final issuer = tbs.elements[base + 2];
      final oid = (sigAlg.elements[0] as ASN1ObjectIdentifier).identifier!;
      return _LeafCert(
        tbs.encodedBytes,
        Uint8List.fromList(sigVal.contentBytes()),
        oid,
        issuer.encodedBytes,
      );
    } on Object {
      return null;
    }
  }

  /// Verifies this certificate's signature against [caKey].
  bool verifiedBy(RSAPublicKey caKey) {
    final makeSigner = _rsaSigners[signatureOid];
    if (makeSigner == null) return false;
    final signer = makeSigner()
      ..init(false, PublicKeyParameter<RSAPublicKey>(caKey));
    try {
      return signer.verifySignature(tbsDer, RSASignature(signature));
    } on Object {
      return false;
    }
  }
}

// --- ASN.1 / X.509 helpers ---------------------------------------------------

ASN1Sequence _certificate(Uint8List der) =>
    ASN1Parser(der).nextObject() as ASN1Sequence;

ASN1Sequence _tbsCertificate(ASN1Sequence cert) =>
    cert.elements[0] as ASN1Sequence;

/// Index of `serialNumber` in a TBSCertificate, skipping the optional, explicit
/// `[0]` version field (DER tag `0xA0`).
int _tbsFieldBase(ASN1Sequence tbs) =>
    (tbs.elements.isNotEmpty && tbs.elements.first.tag == 0xA0) ? 1 : 0;

/// Extracts the RSA public key from a SubjectPublicKeyInfo sequence.
RSAPublicKey _rsaPublicKey(ASN1Sequence spki) {
  final bits = spki.elements[1] as ASN1BitString;
  final key =
      ASN1Parser(Uint8List.fromList(bits.contentBytes())).nextObject()
          as ASN1Sequence;
  final modulus = (key.elements[0] as ASN1Integer).valueAsBigInteger;
  final exponent = (key.elements[1] as ASN1Integer).valueAsBigInteger;
  return RSAPublicKey(modulus, exponent);
}

/// `*WithRSAEncryption` signature OIDs → the matching RSA PKCS#1 v1.5 verifier.
/// The hex strings are the DER-encoded digest algorithm identifiers expected by
/// [RSASigner].
final Map<String, RSASigner Function()> _rsaSigners = {
  '1.2.840.113549.1.1.5': () => RSASigner(SHA1Digest(), '06052b0e03021a'),
  '1.2.840.113549.1.1.11': () =>
      RSASigner(SHA256Digest(), '0609608648016503040201'),
  '1.2.840.113549.1.1.12': () =>
      RSASigner(SHA384Digest(), '0609608648016503040202'),
  '1.2.840.113549.1.1.13': () =>
      RSASigner(SHA512Digest(), '0609608648016503040203'),
};

final RegExp _pemBlock = RegExp(
  '-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----',
  dotAll: true,
);

Iterable<Uint8List> _pemCertificates(String pem) sync* {
  for (final match in _pemBlock.allMatches(pem)) {
    final body = match.group(1)!.replaceAll(RegExp(r'\s'), '');
    if (body.isEmpty) continue;
    yield base64.decode(body);
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
