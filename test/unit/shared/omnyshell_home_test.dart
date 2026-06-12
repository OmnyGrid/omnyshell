@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/src/shared/utils/omnyshell_home.dart';
import 'package:test/test.dart';

void main() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final sep = Platform.pathSeparator;

  group('expandUserHome', () {
    test('leaves absolute and relative paths untouched', () {
      expect(expandUserHome('/srv/app'), '/srv/app');
      expect(expandUserHome('relative/path'), 'relative/path');
      expect(expandUserHome('.omnyshell/run/x'), '.omnyshell/run/x');
    });

    test('does not expand a `~` that is not a path prefix', () {
      expect(expandUserHome('~user/x'), '~user/x');
      expect(expandUserHome('a/~/b'), 'a/~/b');
    });

    test('expands a leading `~/` to the user home', () {
      if (home == null || home.isEmpty) {
        markTestSkipped('no HOME/USERPROFILE in environment');
        return;
      }
      expect(expandUserHome('~/.omnyshell/run/x'), '$home$sep.omnyshell/run/x');
      expect(expandUserHome('~'), home);
    });
  });
}
