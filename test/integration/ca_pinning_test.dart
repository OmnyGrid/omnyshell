import 'dart:io';

import 'package:omnyshell/src/infrastructure/tls/ca_pinning.dart';
import 'package:omnyshell/src/infrastructure/tls/cert_generator.dart';
import 'package:test/test.dart';

/// Resolves a path under `test/support/certs`, relative to the package root.
String _certPath(String name) {
  for (final base in ['test/support/certs', 'support/certs', 'certs']) {
    final candidate = File('$base/$name');
    if (candidate.existsSync()) return candidate.path;
  }
  return 'test/support/certs/$name';
}

/// Starts a TLS server presenting [chainPath]/[keyPath] and returns its port.
Future<SecureServerSocket> _startServer(
  String chainPath,
  String keyPath,
) async {
  final ctx = SecurityContext()
    ..useCertificateChain(chainPath)
    ..usePrivateKey(keyPath);
  final server = await SecureServerSocket.bind('127.0.0.1', 0, ctx);
  server.listen(
    (s) => s.listen((_) {}, onError: (_) {}, cancelOnError: false),
    onError: (_) {},
  );
  return server;
}

/// Attempts a TLS handshake to [port], verifying against [verifyHost] (use a
/// name absent from the certificate's SANs to force a hostname mismatch).
/// Returns true if the handshake succeeded.
Future<bool> _connects(
  int port, {
  required String verifyHost,
  SecurityContext? context,
  bool Function(X509Certificate, String, int)? badCert,
}) async {
  try {
    final raw = await Socket.connect('127.0.0.1', port);
    final socket = await SecureSocket.secure(
      raw,
      host: verifyHost,
      context: context ?? SecurityContext(withTrustedRoots: false),
      onBadCertificate: badCert == null
          ? null
          : (cert) => badCert(cert, verifyHost, port),
    );
    await socket.close();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  group('CaTrust exact pin (self-signed cert as --ca)', () {
    late SecureServerSocket server;

    setUp(() async {
      server = await _startServer(
        _certPath('localhost.crt'),
        _certPath('localhost.key'),
      );
    });

    tearDown(() => server.close());

    test('accepts the pinned self-signed certificate', () async {
      // The fixture is a self-signed cert used as its own anchor, which Dart's
      // chain validation rejects — so the callback fires and the exact-pin path
      // must accept it.
      final pin = caPinnedBadCertificateCallback(_certPath('localhost.crt'));
      expect(
        await _connects(server.port, verifyHost: '127.0.0.1', badCert: pin),
        isTrue,
      );
    });

    test('without the callback the untrusted cert is rejected', () async {
      expect(await _connects(server.port, verifyHost: '127.0.0.1'), isFalse);
    });
  });

  group(
    'CaTrust issued-by-CA (verify-ca, hostname ignored)',
    () {
      late Directory dir;
      late Directory otherDir;
      late SecureServerSocket server;

      setUp(() async {
        dir = Directory.systemTemp.createTempSync('omny-ca-pin');
        otherDir = Directory.systemTemp.createTempSync('omny-ca-pin-other');
        await CertGenerator.generate(outputDir: dir.path);
        await CertGenerator.generate(outputDir: otherDir.path);
        server = await _startServer(
          '${dir.path}/server.crt',
          '${dir.path}/server.key',
        );
      });

      tearDown(() async {
        await server.close();
        dir.deleteSync(recursive: true);
        otherDir.deleteSync(recursive: true);
      });

      test(
        'a CA-trusting context fails on hostname mismatch (the baseline bug)',
        () async {
          final trust = SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificates('${dir.path}/ca.crt');
          expect(
            await _connects(
              server.port,
              verifyHost: 'not-in-san.invalid',
              context: trust,
            ),
            isFalse,
          );
        },
      );

      test('--ca accepts the chain despite the hostname mismatch', () async {
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates('${dir.path}/ca.crt');
        final pin = caPinnedBadCertificateCallback('${dir.path}/ca.crt');
        expect(
          await _connects(
            server.port,
            verifyHost: 'not-in-san.invalid',
            context: trust,
            badCert: pin,
          ),
          isTrue,
        );
      });

      test('a certificate from a different CA is rejected', () async {
        final pin = caPinnedBadCertificateCallback('${otherDir.path}/ca.crt');
        expect(
          await _connects(
            server.port,
            verifyHost: 'not-in-san.invalid',
            badCert: pin,
          ),
          isFalse,
        );
      });
    },
    skip: _opensslMissing() ? 'openssl not available' : null,
  );
}

/// Whether the `openssl` binary needed by [CertGenerator] is unavailable.
bool _opensslMissing() {
  try {
    return Process.runSync('openssl', ['version']).exitCode != 0;
  } on Object {
    return true;
  }
}
