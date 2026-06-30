library;

import 'package:command_shield/command_shield.dart' show CommandSyntax;
import 'package:omnyshell/src/application/client/ide/ide_command_support.dart';
import 'package:omnyshell/src/domain/backend/shell_family.dart';
import 'package:test/test.dart';

void main() {
  group('resolveRemoteIdeRoot', () {
    test('no arg / "." / "" uses the remote cwd', () {
      expect(resolveRemoteIdeRoot(null, '/home/alice'), '/home/alice');
      expect(resolveRemoteIdeRoot('', '/home/alice'), '/home/alice');
      expect(resolveRemoteIdeRoot('.', '/home/alice'), '/home/alice');
    });

    test('an absolute path is used as-is (normalized)', () {
      expect(resolveRemoteIdeRoot('/srv/app/', '/home'), '/srv/app');
      expect(resolveRemoteIdeRoot('/srv/../etc', null), '/etc');
    });

    test('a relative path joins onto the remote cwd', () {
      expect(resolveRemoteIdeRoot('proj', '/home/alice'), '/home/alice/proj');
      expect(resolveRemoteIdeRoot('../x', '/home/alice'), '/home/x');
    });

    test('null when a relative/omitted path needs an unknown cwd', () {
      expect(resolveRemoteIdeRoot(null, null), isNull);
      expect(resolveRemoteIdeRoot('proj', null), isNull);
    });
  });

  group('ideCommandSyntaxFor', () {
    test('maps the shell family to the command_shield syntax', () {
      expect(
        ideCommandSyntaxFor(ShellFamily.powershell),
        CommandSyntax.powershell,
      );
      expect(ideCommandSyntaxFor(ShellFamily.cmd), CommandSyntax.windowsCmd);
      expect(ideCommandSyntaxFor(ShellFamily.posix), CommandSyntax.bash);
      expect(ideCommandSyntaxFor(null), CommandSyntax.bash);
    });
  });
}
