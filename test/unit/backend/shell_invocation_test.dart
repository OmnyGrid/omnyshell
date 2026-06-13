import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/src/infrastructure/backend/shell_invocation.dart';
import 'package:test/test.dart';

void main() {
  group('classifyShellFamily', () {
    test('recognizes PowerShell by basename', () {
      expect(
        classifyShellFamily(
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        ),
        ShellFamily.powershell,
      );
      expect(classifyShellFamily('pwsh.exe'), ShellFamily.powershell);
      expect(classifyShellFamily('/usr/bin/pwsh'), ShellFamily.powershell);
    });

    test('recognizes cmd.exe', () {
      expect(
        classifyShellFamily(r'C:\Windows\System32\cmd.exe'),
        ShellFamily.cmd,
      );
      expect(classifyShellFamily('cmd'), ShellFamily.cmd);
    });

    test('treats anything else (sh/bash/zsh/Git Bash) as POSIX', () {
      expect(classifyShellFamily('/bin/sh'), ShellFamily.posix);
      expect(classifyShellFamily('/bin/bash'), ShellFamily.posix);
      expect(classifyShellFamily('/usr/bin/zsh'), ShellFamily.posix);
      expect(
        classifyShellFamily(r'C:\Program Files\Git\bin\bash.exe'),
        ShellFamily.posix,
      );
    });
  });

  group('defaultShellArgs', () {
    test('posix shells need no args (silent over a pipe)', () {
      expect(defaultShellArgs(ShellFamily.posix), isEmpty);
    });

    test('PowerShell suppresses banner and profile', () {
      expect(defaultShellArgs(ShellFamily.powershell), [
        '-NoLogo',
        '-NoProfile',
      ]);
    });

    test('cmd disables command echo', () {
      expect(defaultShellArgs(ShellFamily.cmd), ['/Q']);
    });
  });

  group('resolveShellInvocation exec with a shellFamily hint', () {
    ShellRequest exec(ShellFamily? family, {List<String> args = const []}) =>
        ShellRequest(
          mode: SessionMode.exec,
          command: 'echo hi',
          args: args,
          shellFamily: family,
        );

    test('no hint falls back to the default exec shell', () {
      final (exe, args) = resolveShellInvocation(exec(null), '/bin/sh');
      expect(exe, '/bin/sh');
      expect(args, [shellCommandFlag, 'echo hi']);
    });

    test('powershell hint runs via PowerShell -Command', () {
      final (exe, args) = resolveShellInvocation(
        exec(ShellFamily.powershell),
        '/bin/sh',
      );
      expect(classifyShellFamily(exe), ShellFamily.powershell);
      expect(args, ['-NoLogo', '-NoProfile', '-Command', 'echo hi']);
    });

    test('cmd hint runs via cmd /c', () {
      final (exe, args) = resolveShellInvocation(
        exec(ShellFamily.cmd),
        '/bin/sh',
      );
      expect(classifyShellFamily(exe), ShellFamily.cmd);
      expect(args, ['/c', 'echo hi']);
    });

    test('posix hint runs via a posix shell -c', () {
      final (exe, args) = resolveShellInvocation(
        exec(ShellFamily.posix),
        '/bin/sh',
      );
      expect(classifyShellFamily(exe), ShellFamily.posix);
      expect(args, ['-c', 'echo hi']);
    });

    test('explicit args bypass the family hint (program run directly)', () {
      final (exe, args) = resolveShellInvocation(
        exec(ShellFamily.powershell, args: const ['-v']),
        '/bin/sh',
      );
      expect(exe, 'echo hi');
      expect(args, const ['-v']);
    });
  });
}
