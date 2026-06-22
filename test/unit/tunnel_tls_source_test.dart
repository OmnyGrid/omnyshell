@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/src/infrastructure/tls/tunnel_tls_source.dart';
import 'package:test/test.dart';

/// Resolves a certificate file shipped with the repo, trying both the support
/// certs and the dev `certs/` directory (run-location dependent).
String _findCert(List<String> candidates) {
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  throw StateError('missing test certificate: $candidates');
}

void main() {
  late Directory dir;
  late String certA;
  late String keyA;
  late String certB;
  late String keyB;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tunnel-tls-');
    certA = _findCert([
      'test/support/certs/localhost.crt',
      'support/certs/localhost.crt',
    ]);
    keyA = _findCert([
      'test/support/certs/localhost.key',
      'support/certs/localhost.key',
    ]);
    certB = _findCert(['certs/server.crt']);
    keyB = _findCert(['certs/server.key']);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void writeCert(String crt, String key) {
    File(
      '${dir.path}/fullchain.pem',
    ).writeAsBytesSync(File(crt).readAsBytesSync());
    File(
      '${dir.path}/privkey.pem',
    ).writeAsBytesSync(File(key).readAsBytesSync());
  }

  test('load builds a context from fullchain.pem + privkey.pem', () {
    writeCert(certA, keyA);
    final source = TunnelTlsSource(dir.path);
    source.load();
    expect(source.context, isNotNull);
  });

  test('reloadIfChanged is a no-op when the files are unchanged', () {
    writeCert(certA, keyA);
    final source = TunnelTlsSource(dir.path);
    source.load();
    final before = source.context;
    expect(source.reloadIfChanged(), isFalse);
    expect(source.context, same(before));
  });

  test('reloadIfChanged rebuilds the context after a renewal', () {
    writeCert(certA, keyA);
    var reloads = 0;
    final source = TunnelTlsSource(dir.path, onReloaded: (_) => reloads++);
    source.load();
    final before = source.context;

    // Simulate a certificate renewal rewriting the files in place.
    writeCert(certB, keyB);

    expect(source.reloadIfChanged(), isTrue);
    expect(source.context, isNot(same(before)));
    expect(reloads, 1);
    // Stable again afterwards.
    expect(source.reloadIfChanged(), isFalse);
  });

  test('reloadIfChanged keeps the old context when new files are invalid', () {
    writeCert(certA, keyA);
    final source = TunnelTlsSource(dir.path);
    source.load();
    final before = source.context;

    // A partial write mid-renewal: garbage cert content.
    File('${dir.path}/fullchain.pem').writeAsStringSync('not a pem');

    expect(source.reloadIfChanged(), isFalse);
    expect(source.context, same(before));
  });
}
