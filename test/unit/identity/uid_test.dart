import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

/// Resolves a path under the test cert support dir, relative to package root.
String _certPath(String name) {
  for (final base in ['test/support/certs', 'support/certs', 'certs']) {
    if (File('$base/$name').existsSync()) return '$base/$name';
  }
  return 'test/support/certs/$name';
}

Uint8List _u8(List<int> b) => Uint8List.fromList(b);

void main() {
  final pubKey = _u8(List<int>.filled(32, 7));

  group('OmnyUid', () {
    test('produced node UID is a valid NodeId and carries the node prefix', () {
      final uid = UidComputer.computeNodeUid(
        publicKey: pubKey,
        machineId: 'm',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      expect(uid.value, startsWith('nod_'));
      expect(uid.isNode, isTrue);
      expect(uid.isHub, isFalse);
      // Must be usable as a NodeId (no exception).
      expect(NodeId(uid.value).value, uid.value);
    });

    test('rejects malformed UIDs', () {
      expect(() => OmnyUid('no-prefix'), throwsA(isA<Object>()));
      expect(() => OmnyUid('nod_with space'), throwsA(isA<Object>()));
    });
  });

  group('UidComputer.computeNodeUid', () {
    test('is deterministic for identical material', () {
      OmnyUid build() => UidComputer.computeNodeUid(
        publicKey: pubKey,
        machineId: 'machine-1',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      expect(build(), equals(build()));
    });

    test('changes when any single input changes', () {
      final base = UidComputer.computeNodeUid(
        publicKey: pubKey,
        machineId: 'machine-1',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      final diffKey = UidComputer.computeNodeUid(
        publicKey: _u8(List<int>.filled(32, 9)),
        machineId: 'machine-1',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      final diffMachine = UidComputer.computeNodeUid(
        publicKey: pubKey,
        machineId: 'machine-2',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      final diffHost = UidComputer.computeNodeUid(
        publicKey: pubKey,
        machineId: 'machine-1',
        os: 'linux',
        arch: 'x64',
        hostname: 'other',
      );
      expect({base, diffKey, diffMachine, diffHost}, hasLength(4));
    });

    test('computes a stable UID for a keyless (token) node', () {
      OmnyUid build() => UidComputer.computeNodeUid(
        publicKey: null,
        machineId: 'machine-1',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      final withKey = UidComputer.computeNodeUid(
        publicKey: pubKey,
        machineId: 'machine-1',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      expect(build(), equals(build()));
      expect(build(), isNot(equals(withKey)));
    });

    test('length-prefixing prevents field-boundary collisions', () {
      // Naive concatenation would make ("ab","c") == ("a","bc").
      final a = UidComputer.computeNodeUid(
        publicKey: pubKey,
        machineId: 'm',
        os: 'ab',
        arch: 'c',
        hostname: 'h',
      );
      final b = UidComputer.computeNodeUid(
        publicKey: pubKey,
        machineId: 'm',
        os: 'a',
        arch: 'bc',
        hostname: 'h',
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('UidComputer.computeHubUid', () {
    test('carries the hub prefix and is domain-separated from nodes', () {
      final material = _u8([1, 2, 3, 4]);
      final hub = UidComputer.computeHubUid(
        keyMaterial: material,
        machineId: 'm',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      final node = UidComputer.computeNodeUid(
        publicKey: material,
        machineId: 'm',
        os: 'linux',
        arch: 'x64',
        hostname: 'host',
      );
      expect(hub.value, startsWith('hub_'));
      // Same bytes, different kind tag -> different UID.
      expect(hub.value.substring(4), isNot(equals(node.value.substring(4))));
    });
  });

  group('CertificateIdentity', () {
    final certBytes = File(_certPath('localhost.crt')).readAsBytesSync();

    test('extracts a SPKI SEQUENCE that is a strict subset of the cert', () {
      final spki = CertificateIdentity.spkiFromCertificate(certBytes);
      expect(spki, isNotNull);
      expect(spki!.first, equals(0x30)); // DER SEQUENCE
      expect(spki.length, lessThan(certBytes.length));
    });

    test('is deterministic', () {
      final a = CertificateIdentity.spkiFromCertificate(certBytes);
      final b = CertificateIdentity.spkiFromCertificate(certBytes);
      expect(a, equals(b));
    });

    test('matches openssl SPKI when openssl is available', () {
      final expected = _opensslSpki(_certPath('localhost.crt'));
      if (expected == null) {
        return; // openssl not present; covered by structural checks above.
      }
      final spki = CertificateIdentity.spkiFromCertificate(certBytes);
      expect(spki, equals(expected));
    });

    test('returns null for non-certificate bytes', () {
      expect(
        CertificateIdentity.spkiFromCertificate(_u8([0, 1, 2, 3])),
        isNull,
      );
    });
  });

  group('UidStore', () {
    late Directory home;
    final uid = UidComputer.computeNodeUid(
      publicKey: pubKey,
      machineId: 'm',
      os: 'linux',
      arch: 'x64',
      hostname: 'host',
    );

    setUp(() => home = Directory.systemTemp.createTempSync('omnyshell-uid'));
    tearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    test('first run establishes and persists the UID', () async {
      final store = UidStore(fileName: 'node.uid', home: home.path);
      final logs = <String>[];
      final res = await store.resolve(uid, logger: logs.add);
      expect(res.firstRun, isTrue);
      expect(res.changed, isFalse);
      expect(res.uid, equals(uid));
      expect(File(store.path).existsSync(), isTrue);
      expect(logs.single, contains('established'));
    });

    test('re-resolving the same UID reports no change', () async {
      final store = UidStore(fileName: 'node.uid', home: home.path);
      await store.resolve(uid);
      final logs = <String>[];
      final res = await store.resolve(uid, logger: logs.add);
      expect(res.firstRun, isFalse);
      expect(res.changed, isFalse);
      expect(logs, isEmpty);
    });

    test(
      'a different UID is reported as a change and retires the old one',
      () async {
        final store = UidStore(fileName: 'node.uid', home: home.path);
        await store.resolve(uid);
        final changed = UidComputer.computeNodeUid(
          publicKey: pubKey,
          machineId: 'm',
          os: 'linux',
          arch: 'x64',
          hostname: 'renamed',
        );
        final logs = <String>[];
        final res = await store.resolve(changed, logger: logs.add);
        expect(res.changed, isTrue);
        expect(res.previous, equals(uid));
        expect(res.uid, equals(changed));
        expect(logs.single, contains('UID changed'));

        final json =
            jsonDecode(File(store.path).readAsStringSync())
                as Map<String, dynamic>;
        expect(json['uid'], equals(changed.value));
        expect((json['previous'] as List).single['uid'], equals(uid.value));
      },
    );

    test('a corrupt file is treated as a re-establishment', () async {
      final store = UidStore(fileName: 'node.uid', home: home.path);
      File(store.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('not json');
      final res = await store.resolve(uid);
      expect(res.changed, isTrue);
      expect(res.previous, isNull);
      expect(res.uid, equals(uid));
    });
  });
}

/// Returns the DER SPKI of [certPath] via openssl, or null if unavailable.
Uint8List? _opensslSpki(String certPath) {
  try {
    final pub = Process.runSync('openssl', [
      'x509',
      '-in',
      certPath,
      '-noout',
      '-pubkey',
    ]);
    if (pub.exitCode != 0) return null;
    final tmp = File('${Directory.systemTemp.path}/omnyshell-spki-$pid.pem')
      ..writeAsStringSync(pub.stdout as String);
    final der = Process.runSync('openssl', [
      'pkey',
      '-pubin',
      '-in',
      tmp.path,
      '-outform',
      'DER',
    ], stdoutEncoding: null);
    tmp.deleteSync();
    if (der.exitCode != 0) return null;
    return Uint8List.fromList(der.stdout as List<int>);
  } on Object {
    return null;
  }
}
