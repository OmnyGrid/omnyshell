import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

void main() {
  group('launchesForegroundProgram', () {
    test('editors and pagers are foreground', () {
      expect(launchesForegroundProgram('nano'), isTrue);
      expect(launchesForegroundProgram('nano /tmp/x'), isTrue);
      expect(launchesForegroundProgram('vim file.txt'), isTrue);
      expect(launchesForegroundProgram('less /var/log/syslog'), isTrue);
      expect(launchesForegroundProgram('man ls'), isTrue);
      expect(launchesForegroundProgram('top'), isTrue);
    });

    test('strips sudo / env / assignments to find the program', () {
      expect(launchesForegroundProgram('sudo vim /etc/hosts'), isTrue);
      expect(launchesForegroundProgram('sudo -u root nano x'), isTrue);
      expect(launchesForegroundProgram('FOO=1 BAR=2 less x'), isTrue);
      expect(launchesForegroundProgram('/usr/bin/nano x'), isTrue);
    });

    test('REPLs are foreground only when bare', () {
      expect(launchesForegroundProgram('python'), isTrue);
      expect(launchesForegroundProgram('python3'), isTrue);
      expect(launchesForegroundProgram('python app.py'), isFalse);
      expect(launchesForegroundProgram('node'), isTrue);
      expect(launchesForegroundProgram('node server.js'), isFalse);
    });

    test('non-interactive commands are not foreground', () {
      expect(launchesForegroundProgram('ls -la'), isFalse);
      expect(launchesForegroundProgram('git status'), isFalse);
      expect(launchesForegroundProgram(''), isFalse);
      expect(launchesForegroundProgram('   '), isFalse);
    });

    test('shell operators defeat foreground detection', () {
      expect(launchesForegroundProgram('ls | less'), isFalse);
      expect(launchesForegroundProgram('vim a; vim b'), isFalse);
      expect(launchesForegroundProgram('nano x &'), isFalse);
    });
  });

  group('mayChangeCwdOrGit', () {
    test('read-only commands do not change state', () {
      expect(mayChangeCwdOrGit('ls'), isFalse);
      expect(mayChangeCwdOrGit('ls -la /tmp'), isFalse);
      expect(mayChangeCwdOrGit('cat file'), isFalse);
      expect(mayChangeCwdOrGit('pwd'), isFalse);
      expect(mayChangeCwdOrGit('echo hi'), isFalse);
      expect(mayChangeCwdOrGit('/bin/ls'), isFalse);
      expect(mayChangeCwdOrGit('sudo cat /etc/shadow'), isFalse);
    });

    test('read-only git subcommands do not change state', () {
      expect(mayChangeCwdOrGit('git status'), isFalse);
      expect(mayChangeCwdOrGit('git log --oneline'), isFalse);
      expect(mayChangeCwdOrGit('git diff'), isFalse);
      expect(mayChangeCwdOrGit('git -C /repo status'), isFalse);
      expect(mayChangeCwdOrGit('git config --get user.name'), isFalse);
    });

    test('state-changing commands warrant a refresh', () {
      expect(mayChangeCwdOrGit('cd /tmp'), isTrue);
      expect(mayChangeCwdOrGit('git checkout main'), isTrue);
      expect(mayChangeCwdOrGit('git config user.name x'), isTrue);
      expect(mayChangeCwdOrGit('rm file'), isTrue);
      expect(mayChangeCwdOrGit('mkdir d'), isTrue);
      expect(mayChangeCwdOrGit('nano file'), isTrue);
    });

    test('shell operators force a refresh (conservative)', () {
      expect(mayChangeCwdOrGit('ls && rm x'), isTrue);
      expect(mayChangeCwdOrGit('cat f | tee g'), isTrue);
      expect(mayChangeCwdOrGit('echo hi > file'), isTrue);
    });

    test('empty line changes nothing', () {
      expect(mayChangeCwdOrGit(''), isFalse);
      expect(mayChangeCwdOrGit('   '), isFalse);
    });
  });
}
