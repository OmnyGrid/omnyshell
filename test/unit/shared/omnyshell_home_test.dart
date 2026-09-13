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

  // A node installed as a service is handed no HOME: systemd gives a system
  // unit PATH, LANG and even USER, but sets HOME only if the unit asks for it.
  // Every session the node opened inherited that gap — `cd ~` went nowhere and
  // said nothing, and anything keeping state under a home directory wrote
  // somewhere else.
  group('resolveUserHome', () {
    late Directory dir;
    late String passwd;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omnyshell-passwd');
      passwd = '${dir.path}/passwd';
      File(passwd).writeAsStringSync(
        'root:x:0:0:root:/root:/bin/bash\n'
        'deploy:x:1000:1000:Deploy,,,:/home/deploy:/bin/sh\n'
        'broken:x:1\n',
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('prefers the environment, and looks no further', () {
      expect(
        resolveUserHome(
          environment: {'HOME': '/home/alice', 'USER': 'deploy'},
          passwdPath: passwd,
        ),
        '/home/alice',
        reason: 'an explicit HOME is the answer, whoever the user is',
      );
      expect(
        resolveUserHome(
          environment: {'USERPROFILE': r'C:\Users\alice'},
          passwdPath: passwd,
        ),
        r'C:\Users\alice',
      );
    });

    test('falls back to the password database', () {
      // What a systemd unit's environment actually looks like: a user, no home.
      expect(
        resolveUserHome(
          environment: {'USER': 'deploy', 'PATH': '/usr/bin', 'LANG': 'C'},
          passwdPath: passwd,
        ),
        '/home/deploy',
      );
      expect(
        resolveUserHome(environment: {'LOGNAME': 'root'}, passwdPath: passwd),
        '/root',
      );
    });

    test('an empty HOME is no answer at all', () {
      // Set-but-empty is how a half-configured unit presents, and taking it at
      // face value would put the home directory at the filesystem root.
      expect(
        resolveUserHome(
          environment: {'HOME': '', 'USER': 'deploy'},
          passwdPath: passwd,
        ),
        '/home/deploy',
      );
    });

    test('root is known even with no password database', () {
      // A trimmed container image may carry no /etc/passwd, and root's home is
      // the one answer every Unix agrees on.
      expect(
        resolveUserHome(
          environment: {'USER': 'root'},
          passwdPath: '${dir.path}/absent',
        ),
        '/root',
      );
    });

    test('falls back to the uid when there is no name either', () {
      // A bare container hands its process neither HOME nor USER, so the uid is
      // the only key left — and it is the real one.
      final status = '${dir.path}/status';
      File(
        status,
      ).writeAsStringSync('Name:\tdart\nUid:\t1000\t1000\t1000\t1000\n');

      expect(
        resolveUserHome(
          environment: const {},
          passwdPath: passwd,
          procStatusPath: status,
        ),
        '/home/deploy',
      );
    });

    test('root is root, even with nothing to go on', () {
      final status = '${dir.path}/status';
      File(status).writeAsStringSync('Uid:\t0\t0\t0\t0\n');

      expect(
        resolveUserHome(
          environment: const {},
          passwdPath: '${dir.path}/absent',
          procStatusPath: status,
        ),
        '/root',
      );
    });

    test('says nothing rather than guessing', () {
      // A wrong home is worse than none: it would send git, ssh and package
      // managers to a directory that is not the user's.
      expect(
        resolveUserHome(
          environment: {'USER': 'nobody-here'},
          passwdPath: passwd,
          procStatusPath: '${dir.path}/absent',
        ),
        isNull,
      );
      expect(
        resolveUserHome(
          environment: const {},
          passwdPath: passwd,
          procStatusPath: '${dir.path}/absent',
        ),
        isNull,
      );
    });

    test('an unknown uid is not mistaken for a known one', () {
      final status = '${dir.path}/status';
      File(status).writeAsStringSync('Uid:\t4242\t4242\t4242\t4242\n');

      expect(
        resolveUserHome(
          environment: const {},
          passwdPath: passwd,
          procStatusPath: status,
        ),
        isNull,
      );
    });

    test('a malformed password line is skipped, not fatal', () {
      expect(
        resolveUserHome(
          environment: {'USER': 'broken'},
          passwdPath: passwd,
          // Pinned at something absent, so this asserts the passwd parsing
          // rather than whatever uid the test runner happens to have.
          procStatusPath: '${dir.path}/absent',
        ),
        isNull,
      );
    });
  });

  group('withUserHome', () {
    test('leaves an environment that already carries HOME alone', () {
      expect(
        withUserHome({'HOME': '/explicit', 'TERM': 'xterm'})['HOME'],
        '/explicit',
      );
    });

    test('adds nothing when the child will inherit a HOME anyway', () {
      final env = withUserHome(
        {'TERM': 'xterm'},
        processEnvironment: {'HOME': '/home/deploy'},
      );
      expect(
        env.containsKey('HOME'),
        isFalse,
        reason: 'the child inherits it; overriding would be a lie',
      );
      expect(env['TERM'], 'xterm');
    });

    test('fills HOME in when the process itself has none', () {
      // The case this exists for: a node started by systemd, opening a session.
      final dir = Directory.systemTemp.createTempSync('omnyshell-passwd-env');
      addTearDown(() => dir.deleteSync(recursive: true));
      final passwd = '${dir.path}/passwd';
      File(
        passwd,
      ).writeAsStringSync('deploy:x:1000:1000::/home/deploy:/bin/sh');

      final env = withUserHome(
        {'TERM': 'xterm'},
        processEnvironment: {'USER': 'deploy', 'PATH': '/usr/bin'},
        passwdPath: passwd,
      );
      expect(env['HOME'], '/home/deploy');
      expect(env['TERM'], 'xterm');
    });

    test('stays quiet when there is no home to be found', () {
      final env = withUserHome(
        {'TERM': 'xterm'},
        processEnvironment: const {},
        passwdPath: '/nonexistent',
        procStatusPath: '/nonexistent',
      );
      expect(env.containsKey('HOME'), isFalse);
    });
  });
}
