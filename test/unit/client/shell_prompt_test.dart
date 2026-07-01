library;

import 'package:omnyshell/src/application/client/shell_prompt.dart';
import 'package:test/test.dart';

void main() {
  final esc = String.fromCharCode(27); // ESC, the ANSI introducer

  group('formatShellPrompt', () {
    test('plain (no color): bare user@node:cwd', () {
      expect(
        formatShellPrompt(
          principal: 'alice',
          node: 'web',
          cwd: '/home',
          color: false,
        ),
        r'alice@web:/home $ ',
      );
    });

    test('plain: git segment with branch and status counts', () {
      expect(
        formatShellPrompt(
          principal: 'alice',
          node: 'web',
          cwd: '/home',
          branch: 'main',
          gitStatus: '+1',
          color: false,
        ),
        r'alice@web:/home git(main +1) $ ',
      );
    });

    test('plain: privilege warning', () {
      expect(
        formatShellPrompt(
          principal: 'root',
          node: 'web',
          cwd: '/',
          privilege: 'root',
          color: false,
        ),
        r'root@web:/ (⚠ root) $ ',
      );
    });

    test('colored: user@node green, cwd cyan', () {
      expect(
        formatShellPrompt(principal: 'alice', node: 'web', cwd: '/home'),
        '$esc[32malice@web$esc[0m:$esc[36m/home$esc[0m \$ ',
      );
    });

    test('colored: git segment blue with red branch and green counts', () {
      expect(
        formatShellPrompt(
          principal: 'alice',
          node: 'web',
          cwd: '/home',
          branch: 'main',
          gitStatus: '+1',
        ),
        '$esc[32malice@web$esc[0m:$esc[36m/home$esc[0m '
        '$esc[34mgit($esc[31mmain$esc[32m +1$esc[31m$esc[0m'
        '$esc[34m)$esc[0m \$ ',
      );
    });
  });

  group('formatShellPrompt width-aware compaction', () {
    // A full prompt whose plain width is 61 columns.
    String at(int width) => formatShellPrompt(
      principal: 'alice',
      node: 'web-01',
      cwd: '/var/www/omnygrid/omnyshell',
      branch: 'master',
      gitStatus: '+2 ~1',
      color: false,
      width: width,
    );

    test('wide terminal keeps the full form (equals no width)', () {
      final full = formatShellPrompt(
        principal: 'alice',
        node: 'web-01',
        cwd: '/var/www/omnygrid/omnyshell',
        branch: 'master',
        gitStatus: '+2 ~1',
        color: false,
      );
      expect(at(200), full);
      expect(at(200), r'alice@web-01:/var/www/omnygrid/omnyshell git(master +2 ~1) $ ');
    });

    test('width 0 (unknown) never compacts', () {
      expect(at(0), contains('+2 ~1'));
      expect(at(0), contains('@web-01'));
    });

    test('level 1: drops the git status counts', () {
      expect(at(73), r'alice@web-01:/var/www/omnygrid/omnyshell git(master) $ ');
    });

    test('level 2: also drops @node', () {
      expect(at(66), r'alice:/var/www/omnygrid/omnyshell git(master) $ ');
    });

    test('level 3: also shortens cwd to …/basename', () {
      expect(at(50), r'alice:…/omnyshell git(master) $ ');
    });

    test('level 4: also drops the git segment', () {
      expect(at(40), r'alice:…/omnyshell $ ');
    });

    test('too narrow for any level falls back to the most compact', () {
      expect(at(10), r'alice:…/omnyshell $ ');
    });

    test('colored form compacts too (level 3)', () {
      expect(
        formatShellPrompt(
          principal: 'alice',
          node: 'web-01',
          cwd: '/var/www/omnygrid/omnyshell',
          branch: 'master',
          gitStatus: '+2 ~1',
          width: 50,
        ),
        '$esc[32malice$esc[0m:$esc[36m…/omnyshell$esc[0m '
        '$esc[34mgit($esc[31mmaster$esc[0m$esc[34m)$esc[0m \$ ',
      );
    });

    test('privilege warning survives compaction', () {
      expect(
        formatShellPrompt(
          principal: 'root',
          node: 'web-01',
          cwd: '/var/www/omnygrid/omnyshell',
          privilege: 'root',
          color: false,
          width: 10,
        ),
        r'root:…/omnyshell (⚠ root) $ ',
      );
    });

    group('cwd shortening edge cases (forced most-compact level)', () {
      String short(String cwd) => formatShellPrompt(
        principal: 'alice',
        node: 'web',
        cwd: cwd,
        color: false,
        width: 1,
      );

      test('root stays as-is', () => expect(short('/'), r'alice:/ $ '));
      test('no separator stays as-is',
          () => expect(short('home'), r'alice:home $ '));
      test('windows path uses last segment',
          () => expect(short(r'C:\a\b'), r'alice:…/b $ '));
    });
  });
}
