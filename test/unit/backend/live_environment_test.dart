import 'dart:io';

import 'package:omnyshell/src/infrastructure/backend/live_environment.dart';
import 'package:test/test.dart';

List<int> _block(List<String> entries) => [
  for (final e in entries) ...[...e.codeUnits, 0],
  0,
];

void main() {
  group('parseEnvironmentBlock', () {
    test('reads NAME=value entries up to the empty one', () {
      expect(
        parseEnvironmentBlock(_block(['Path=C:\\a;C:\\b', 'OS=Windows_NT'])),
        {'Path': r'C:\a;C:\b', 'OS': 'Windows_NT'},
      );
    });

    test('keeps "=" inside a value', () {
      expect(parseEnvironmentBlock(_block(['OPTS=a=b'])), {'OPTS': 'a=b'});
    });

    test('skips the hidden per-drive cwd entries', () {
      expect(parseEnvironmentBlock(_block([r'=C:=C:\x', 'A=1'])), {'A': '1'});
    });

    test('ignores anything after the terminating empty entry', () {
      expect(
        parseEnvironmentBlock([
          ..._block(['A=1']),
          ...'B=2'.codeUnits,
        ]),
        {'A': '1'},
      );
    });

    test('reads non-ASCII values', () {
      expect(parseEnvironmentBlock(_block(['NAME=Gracílio ✓'])), {
        'NAME': 'Gracílio ✓',
      });
    });
  });

  group('overlayEnvironment', () {
    test('case-insensitive: replaces a name and keeps its spelling', () {
      final out = overlayEnvironment(
        {'Path': 'old', 'HOME': 'h'},
        {'PATH': 'new', 'NEW_VAR': 'n'},
        caseInsensitive: true,
      );
      expect(out.keys, ['Path', 'HOME', 'NEW_VAR']);
      expect(out['Path'], 'new');
      // Looked up regardless of case, like Platform.environment on Windows.
      expect(out['PATH'], 'new');
      expect(out['path'], 'new');
    });

    test('case-sensitive: different spellings are different names', () {
      final out = overlayEnvironment(
        {'Path': 'old'},
        {'PATH': 'new'},
        caseInsensitive: false,
      );
      expect(out, {'Path': 'old', 'PATH': 'new'});
    });

    test('keeps variables only the base has', () {
      final out = overlayEnvironment(
        {'OMNYSHELL_HOME': '/x'},
        {'PATH': 'p'},
        caseInsensitive: true,
      );
      expect(out['OMNYSHELL_HOME'], '/x');
    });
  });

  group('liveProcessEnvironment', () {
    test('is this process\'s environment off Windows', () {
      expect(liveProcessEnvironment(), same(Platform.environment));
      expect(refreshedVariables(liveProcessEnvironment()), isEmpty);
    }, skip: Platform.isWindows ? 'POSIX behaviour' : null);

    test(
      'on Windows, includes the node\'s variables and looks names up '
      'case-insensitively',
      () {
        final live = liveProcessEnvironment();
        expect(live['path'], isNotNull);
        expect(live['SystemRoot'], Platform.environment['SystemRoot']);
      },
      tags: ['windows'],
      skip: Platform.isWindows ? null : 'Windows only',
    );

    test(
      'refreshedVariables returns only what differs from this process',
      () {
        final live = liveProcessEnvironment();
        final changed = refreshedVariables(live);
        for (final MapEntry(:key, :value) in changed.entries) {
          expect(Platform.environment[key], isNot(value));
        }
      },
      tags: ['windows'],
      skip: Platform.isWindows ? null : 'Windows only',
    );
  });

  test('windowsRegistryEnvironment is null off Windows', () {
    expect(windowsRegistryEnvironment(), isNull);
  }, skip: Platform.isWindows ? 'POSIX behaviour' : null);
}
