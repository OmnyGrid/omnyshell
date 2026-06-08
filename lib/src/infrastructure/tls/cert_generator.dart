import 'dart:io';

/// The paths of the TLS files produced by [CertGenerator.generate].
class GeneratedCertificates {
  /// CA certificate — clients and nodes trust this (`--ca`).
  final String caCert;

  /// CA private key — keep local; never deploy.
  final String caKey;

  /// Hub server certificate chain (leaf + CA) for `hub start --cert`.
  final String serverCert;

  /// Hub server private key for `hub start --key`.
  final String serverKey;

  const GeneratedCertificates({
    required this.caCert,
    required this.caKey,
    required this.serverCert,
    required this.serverKey,
  });
}

/// Generates the TLS certificate material an OmnyShell Hub needs to run.
///
/// OmnyShell is secure-by-default: the Hub only speaks WebSocket-on-TLS, so
/// `hub start` requires a server certificate and key, and clients/nodes must
/// trust the issuing CA. This creates a small local CA and a server certificate
/// signed by it (a CA → leaf chain, since a bare self-signed *leaf* used as its
/// own trust anchor is rejected by Dart's TLS stack).
///
/// The work is delegated to the system `openssl` binary, which must be on the
/// `PATH`.
class CertGenerator {
  /// Generate a CA plus a Hub server certificate into [outputDir].
  ///
  /// [hosts] are extra SAN DNS entries; `localhost` and `127.0.0.1` are always
  /// included. [commonName] is the server certificate's CN, [caCommonName] the
  /// CA's. [caDays]/[serverDays] set validity. If `<outputDir>/server.crt`
  /// already exists, the call throws unless [force] is set.
  static Future<GeneratedCertificates> generate({
    required String outputDir,
    List<String> hosts = const [],
    String commonName = 'localhost',
    String caCommonName = 'OmnyShell Dev CA',
    int caDays = 3650,
    int serverDays = 825,
    bool force = false,
  }) async {
    final caCert = '$outputDir/ca.crt';
    final caKey = '$outputDir/ca.key';
    final serverCert = '$outputDir/server.crt';
    final serverKey = '$outputDir/server.key';
    final serverCsr = '$outputDir/server.csr';
    final serverLeaf = '$outputDir/server-leaf.crt';
    final caSerial = '$outputDir/ca.srl';

    if (!force && File(serverCert).existsSync()) {
      throw const CertGeneratorException(
        'certificates already exist in the output directory — '
        'pass --force to regenerate',
      );
    }

    await _requireOpenssl();
    Directory(outputDir).createSync(recursive: true);

    // Subject Alternative Names the server certificate is valid for.
    final san = StringBuffer('DNS:localhost,IP:127.0.0.1');
    for (final host in hosts) {
      if (host.isNotEmpty) san.write(',DNS:$host');
    }

    // 1. Local CA.
    await _openssl([
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      caKey,
      '-out',
      caCert,
      '-days',
      '$caDays',
      '-subj',
      '/CN=$caCommonName',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,keyCertSign,cRLSign',
    ]);

    // 2. Server key + CSR.
    await _openssl([
      'req',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      serverKey,
      '-out',
      serverCsr,
      '-subj',
      '/CN=$commonName',
    ]);

    // 3. Sign the server certificate with the CA. The extensions go in a temp
    //    file (bash process substitution has no Dart equivalent).
    final extFile = File(
      '${Directory.systemTemp.path}/omnyshell-cert-ext-$pid.cnf',
    );
    try {
      extFile.writeAsStringSync(
        'subjectAltName=$san\n'
        'basicConstraints=critical,CA:FALSE\n'
        'keyUsage=critical,digitalSignature,keyEncipherment\n'
        'extendedKeyUsage=serverAuth\n',
      );
      await _openssl([
        'x509',
        '-req',
        '-in',
        serverCsr,
        '-CA',
        caCert,
        '-CAkey',
        caKey,
        '-CAcreateserial',
        '-out',
        serverLeaf,
        '-days',
        '$serverDays',
        '-extfile',
        extFile.path,
      ]);
    } finally {
      if (extFile.existsSync()) extFile.deleteSync();
    }

    // 4. The Hub presents the full chain (leaf + CA) so clients can build the
    //    verification path.
    File(serverCert).writeAsStringSync(
      File(serverLeaf).readAsStringSync() + File(caCert).readAsStringSync(),
    );

    // 5. Clean up intermediates.
    for (final path in [serverCsr, serverLeaf, caSerial]) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }

    return GeneratedCertificates(
      caCert: caCert,
      caKey: caKey,
      serverCert: serverCert,
      serverKey: serverKey,
    );
  }

  static Future<void> _requireOpenssl() async {
    try {
      final result = await Process.run('openssl', ['version']);
      if (result.exitCode != 0) {
        throw CertGeneratorException(
          'openssl is required but failed to run: ${result.stderr}',
        );
      }
    } on ProcessException {
      throw const CertGeneratorException(
        'openssl is required but was not found on PATH',
      );
    }
  }

  static Future<void> _openssl(List<String> args) async {
    final result = await Process.run('openssl', args);
    if (result.exitCode != 0) {
      throw CertGeneratorException(
        'openssl ${args.first} failed (exit ${result.exitCode}): '
        '${(result.stderr as String).trim()}',
      );
    }
  }
}

/// Thrown when certificate generation cannot complete.
class CertGeneratorException implements Exception {
  final String message;
  const CertGeneratorException(this.message);

  @override
  String toString() => message;
}
