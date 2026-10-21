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

  group('mergeEnvironment', () {
    test('later layers win', () {
      expect(
        mergeEnvironment([
          {'A': '1', 'B': '1'},
          {'B': '2'},
          {'C': '3'},
        ]),
        {'A': '1', 'B': '2', 'C': '3'},
      );
    });

    test(
      'on Windows, one variable per name whatever its case, first spelling '
      'kept',
      () {
        final out = mergeEnvironment([
          {'Path': 'inherited', 'HOME': 'h'},
          {'PATH': 'profile'},
        ]);
        // Never both `Path` and `PATH`: the child would see the first only.
        expect(out.keys, ['Path', 'HOME']);
        expect(out['Path'], 'profile');
        expect(out['path'], 'profile');
      },
      tags: ['windows'],
      skip: Platform.isWindows ? null : 'Windows only',
    );

    test('off Windows, different spellings are different names', () {
      expect(
        mergeEnvironment([
          {'Path': 'a'},
          {'PATH': 'b'},
        ]),
        {'Path': 'a', 'PATH': 'b'},
      );
    }, skip: Platform.isWindows ? 'POSIX behaviour' : null);
  });

  group('reconcileEnvironment', () {
    Map<String, String> reconcile(
      Map<String, String> own,
      Map<String, String> startup,
      Map<String, String> now,
    ) =>
        reconcileEnvironment(own: own, startupRegistry: startup, registry: now);

    test('an inherited variable follows the registry', () {
      expect(
        reconcile({'JAVA_HOME': 'jdk17'}, {'JAVA_HOME': 'jdk17'}, {
          'JAVA_HOME': 'jdk21',
        })['JAVA_HOME'],
        'jdk21',
      );
    });

    test('a variable the launcher set is kept', () {
      // e.g. a developer prompt or venv set it; the registry has another value.
      expect(
        reconcile({'JAVA_HOME': 'mine'}, {'JAVA_HOME': 'jdk17'}, {
          'JAVA_HOME': 'jdk21',
        })['JAVA_HOME'],
        'mine',
      );
    });

    test('a variable only the launcher has is kept', () {
      expect(
        reconcile({'OMNYSHELL_HOME': r'C:\data'}, {}, {})['OMNYSHELL_HOME'],
        r'C:\data',
      );
    });

    test('a variable added to the registry appears', () {
      expect(reconcile({}, {}, {'NEW_TOOL': 'x'})['NEW_TOOL'], 'x');
    });

    test('an inherited variable removed from the registry goes', () {
      final out = reconcile({'OLD_TOOL': 'x'}, {'OLD_TOOL': 'x'}, {});
      expect(out.containsKey('OLD_TOOL'), isFalse);
    });

    test('a launcher-set variable survives its removal from the registry', () {
      final out = reconcile({'OLD_TOOL': 'mine'}, {'OLD_TOOL': 'x'}, {});
      expect(out['OLD_TOOL'], 'mine');
    });

    test('PATH: launcher entries stay in front of the current registry', () {
      final out = reconcile(
        {'PATH': r'C:\venv\Scripts;C:\sys;C:\user'},
        {'PATH': r'C:\sys;C:\user'},
        {'PATH': r'C:\sys;C:\user;C:\new'},
      );
      expect(out['PATH'], r'C:\venv\Scripts;C:\sys;C:\user;C:\new');
    });

    test('PATH: a service node gets the registry PATH as it is now', () {
      final out = reconcile({'PATH': r'C:\sys'}, {'PATH': r'C:\sys'}, {
        'PATH': r'C:\sys;C:\new',
      });
      expect(out['PATH'], r'C:\sys;C:\new');
    });

    test('PATH: an entry removed from the registry is dropped', () {
      final out = reconcile(
        {'PATH': r'C:\sys;C:\gone'},
        {'PATH': r'C:\sys;C:\gone'},
        {'PATH': r'C:\sys'},
      );
      expect(out['PATH'], r'C:\sys');
    });

    test('PATH: entries compare ignoring case and trailing separators', () {
      final out = reconcile(
        {'PATH': r'C:\Sys\;C:\user'},
        {'PATH': r'c:\sys;C:\user'},
        {'PATH': r'C:\sys;C:\user'},
      );
      expect(out['PATH'], r'C:\sys;C:\user');
    });

    test(
      'on Windows, names match whatever their case',
      () {
        final out = reconcile(
          {'Path': r'C:\venv;C:\sys'},
          {'PATH': r'C:\sys'},
          {'PATH': r'C:\sys;C:\new'},
        );
        expect(out.keys.where((k) => k.toUpperCase() == 'PATH'), ['Path']);
        expect(out['PATH'], r'C:\venv;C:\sys;C:\new');
      },
      tags: ['windows'],
      skip: Platform.isWindows ? null : 'Windows only',
    );
  });

  group('liveProcessEnvironment', () {
    test('is this process\'s environment off Windows', () {
      expect(liveProcessEnvironment(), same(Platform.environment));
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
      'on Windows, keeps the PATH entries this process\'s launcher added',
      () {
        // The test runner's PATH holds entries no registry has (CI adds the
        // Dart SDK this way); they must not be lost to the registry's PATH.
        final registryPath = windowsRegistryEnvironment()?['PATH'] ?? '';
        final added = Platform.environment['PATH']!
            .split(';')
            .where((e) => e.trim().isNotEmpty && !registryPath.contains(e));
        final live = liveProcessEnvironment()['PATH']!;
        for (final entry in added) {
          expect(live, contains(entry));
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
