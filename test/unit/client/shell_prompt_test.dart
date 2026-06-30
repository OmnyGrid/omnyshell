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
}
