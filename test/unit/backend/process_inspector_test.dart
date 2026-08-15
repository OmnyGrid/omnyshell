import 'dart:io';

import 'package:omnyshell/src/infrastructure/backend/process_inspector.dart';
import 'package:test/test.dart';

void main() {
  group('inspectProcess', () {
    test('resolves the cwd of the current process', () async {
      final snap = await inspectProcess(pid);
      expect(snap.cwd, isNotNull);
      // Compare canonicalised paths (cwd queries resolve symlinks).
      final expected = Directory.current.resolveSymbolicLinksSync();
      final actual = Directory(snap.cwd!).resolveSymbolicLinksSync();
      expect(actual, equals(expected));
    }, onPlatform: {'windows': const Skip('process inspection is POSIX-only')});

    test('returns an empty snapshot for an impossible pid', () async {
      final snap = await inspectProcess(-1);
      expect(snap.command, isNull);
      expect(snap.cwd, isNull);
    });
  });
}
