@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/src/infrastructure/identity/certificate_names.dart';
import 'package:test/test.dart';

/// Resolves a committed test certificate file, tolerating the two locations the
/// suite may run from (package root or `test/`).
String _certPath(String name) {
  for (final base in ['test/support/certs', 'support/certs']) {
    final f = File('$base/$name');
    if (f.existsSync()) return f.path;
  }
  throw StateError('missing test certificate: $name');
}

void main() {
  test('extracts the SAN dNSName from a PEM certificate', () {
    final pem = File(_certPath('localhost.crt')).readAsBytesSync();
    // localhost.crt carries SAN "DNS:localhost, IP Address:127.0.0.1"; the IP
    // entry is skipped in favour of the DNS name.
    expect(CertificateNames.primaryDnsName(pem), 'localhost');
  });

  test('returns null for bytes that are not a certificate', () {
    expect(
      CertificateNames.primaryDnsName(Uint8List.fromList([1, 2, 3, 4])),
      isNull,
    );
    expect(
      CertificateNames.primaryDnsName(
        Uint8List.fromList('not a pem'.codeUnits),
      ),
      isNull,
    );
  });
}
