@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/src/infrastructure/tls/pem_tls_source.dart';
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
  late Directory dir;
  late List<int> chain;
  late List<int> key;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pem-tls-');
    chain = File(_certPath('localhost.crt')).readAsBytesSync();
    key = File(_certPath('localhost.key')).readAsBytesSync();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void writeFullchain(List<int> bytes) =>
      File('${dir.path}/fullchain.pem').writeAsBytesSync(bytes);

  void writeKey() => File('${dir.path}/privkey.pem').writeAsBytesSync(key);

  test('load builds a context from fullchain.pem + privkey.pem', () {
    writeFullchain(chain);
    writeKey();
    final source = PemTlsSource(dir.path);
    source.load();
    expect(source.context, isNotNull);
  });

  test('reloadIfChanged is a no-op when the files are unchanged', () {
    writeFullchain(chain);
    writeKey();
    final source = PemTlsSource(dir.path);
    source.load();
    final before = source.context;
    expect(source.reloadIfChanged(), isFalse);
    expect(source.context, same(before));
  });

  test('reloadIfChanged rebuilds the context after a renewal', () {
    writeFullchain(chain);
    writeKey();
    var reloads = 0;
    final source = PemTlsSource(dir.path, onReloaded: (_) => reloads++);
    source.load();
    final before = source.context;

    // Simulate a renewal rewriting fullchain.pem with new bytes. A leading
    // comment (skipped by PEM parsers) keeps it a valid, parseable certificate
    // while changing the on-disk content the reloader keys on.
    writeFullchain([...'# renewed\n'.codeUnits, ...chain]);

    expect(source.reloadIfChanged(), isTrue);
    expect(source.context, isNot(same(before)));
    expect(reloads, 1);
    // Stable again once the new content is recorded.
    expect(source.reloadIfChanged(), isFalse);
  });

  test('reloadIfChanged keeps the old context when new files are invalid', () {
    writeFullchain(chain);
    writeKey();
    final source = PemTlsSource(dir.path);
    source.load();
    final before = source.context;

    // A partial write mid-renewal: garbage cert content.
    File('${dir.path}/fullchain.pem').writeAsStringSync('not a pem');

    expect(source.reloadIfChanged(), isFalse);
    expect(source.context, same(before));
  });
}
