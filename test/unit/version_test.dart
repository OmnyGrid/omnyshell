@Tags(['version'])
library;

import 'dart:io';

import 'package:omnyshell/omnyshell.dart' show omnyShellVersion;
import 'package:test/test.dart';

void main() {
  group('omnyShellVersion', () {
    test('matches the version declared in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml');
      expect(
        pubspec.existsSync(),
        isTrue,
        reason: 'test must run from the package root',
      );

      final match = RegExp(
        r'''^version:\s*['"]?([^'"\s]+)''',
        multiLine: true,
      ).firstMatch(pubspec.readAsStringSync());

      expect(
        match,
        isNotNull,
        reason: 'no version: line found in pubspec.yaml',
      );

      expect(
        omnyShellVersion,
        equals(match!.group(1)),
        reason:
            'omnyShellVersion (lib/src/version.dart) is out of sync with '
            'pubspec.yaml — update the constant when bumping the version',
      );
    });
  });
}
