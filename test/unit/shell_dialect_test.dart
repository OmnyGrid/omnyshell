import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('ShellDialect.forFamily', () {
    test('maps each family to its dialect', () {
      expect(
        ShellDialect.forFamily(ShellFamily.posix),
        isA<PosixShellDialect>(),
      );
      expect(
        ShellDialect.forFamily(ShellFamily.powershell),
        isA<PowerShellDialect>(),
      );
      expect(ShellDialect.forFamily(ShellFamily.cmd), isA<CmdShellDialect>());
    });
  });

  group('PosixShellDialect', () {
    const dialect = PosixShellDialect();
    final marker = CwdMarker('abc');

    test('init installs a no-op INT trap', () {
      expect(dialect.initLine, "trap ':' INT");
    });

    test('markers delegate to CwdMarker unchanged', () {
      expect(dialect.fullMarker(marker), marker.command);
      expect(dialect.pingMarker(marker), marker.pingCommand);
    });

    test('interactive wrap toggles echo around an eval body', () {
      final cmd = dialect.wrapCommand(
        'ls -l',
        interactive: true,
        tail: dialect.pingMarker(marker),
      );
      expect(
        cmd,
        "stty echo 2>/dev/null ; eval 'ls -l' ; ${marker.pingCommand}"
        ' ; stty -echo 2>/dev/null',
      );
    });

    test('non-interactive wrap omits the stty toggles', () {
      final cmd = dialect.wrapCommand(
        'pwd',
        interactive: false,
        tail: dialect.fullMarker(marker),
      );
      expect(cmd, "eval 'pwd' ; ${marker.command}");
    });

    test('single quotes in the command are escaped for eval', () {
      final cmd = dialect.wrapCommand(
        "echo 'hi'",
        interactive: false,
        tail: 'M',
      );
      expect(cmd, "eval 'echo '\\''hi'\\''' ; M");
    });
  });

  group('PowerShellDialect', () {
    const dialect = PowerShellDialect();
    final marker = CwdMarker('abc');

    test('init suppresses the prompt', () {
      expect(dialect.initLine, contains('function prompt'));
    });

    test('full marker emits the token split, never verbatim', () {
      final cmd = dialect.fullMarker(marker);
      final (a, b) = marker.tokenHalves;
      expect(cmd, isNot(contains(marker.token)));
      expect(cmd, contains("'$a'+'$b'"));
    });

    test('full marker queries branch, status and privilege', () {
      final cmd = dialect.fullMarker(marker);
      expect(cmd, contains('git rev-parse --abbrev-ref HEAD'));
      expect(cmd, contains('git status --porcelain'));
      expect(cmd, contains('Administrator'));
      expect(cmd, contains(r'$PWD.Path'));
    });

    test('ping marker emits only the token and newline', () {
      final cmd = dialect.pingMarker(marker);
      expect(cmd, isNot(contains(marker.token)));
      expect(cmd, isNot(contains('git')));
      expect(cmd, contains('[char]10'));
    });

    test('wrap chains the marker with a statement separator, no echo', () {
      final cmd = dialect.wrapCommand(
        'Get-ChildItem',
        interactive: true,
        tail: 'M',
      );
      expect(cmd, 'Get-ChildItem ; M');
      expect(cmd, isNot(contains('stty')));
    });

    test('the emitted marker line round-trips through CwdMarker', () {
      // The dialect promises this output line shape; verify the parser reads it.
      final out = '${marker.token}C:\\src\tmain\t+1 ~2 ?3\troot\n';
      final scan = marker.feed(_b(out));
      expect(scan.cwd, r'C:\src');
      expect(scan.branch, 'main');
      expect(scan.gitStatus, '+1 ~2 ?3');
      expect(scan.privilege, 'root');
      expect(scan.completed, isTrue);
    });
  });

  group('CmdShellDialect', () {
    const dialect = CmdShellDialect();
    final marker = CwdMarker('abc');

    test('init shrinks the prompt', () {
      expect(dialect.initLine, r'prompt $G');
    });

    test('full marker emits cwd via %CD%, token split across set /p', () {
      final cmd = dialect.fullMarker(marker);
      final (a, b) = marker.tokenHalves;
      expect(cmd, isNot(contains(marker.token)));
      expect(cmd, contains('%CD%'));
      expect(cmd, contains('"=$a"'));
      expect(cmd, contains('"=$b%CD%"'));
    });

    test('ping marker emits the token and a newline only', () {
      final cmd = dialect.pingMarker(marker);
      expect(cmd, isNot(contains(marker.token)));
      expect(cmd, isNot(contains('%CD%')));
      expect(cmd, contains('echo.'));
    });

    test('wrap chains the marker with & (runs regardless of exit)', () {
      final cmd = dialect.wrapCommand('dir', interactive: true, tail: 'M');
      expect(cmd, 'dir & M');
    });

    test('cwd-only output round-trips (no git/priv fields)', () {
      final out = '${marker.token}C:\\Users\\me\n';
      final scan = marker.feed(_b(out));
      expect(scan.cwd, r'C:\Users\me');
      expect(scan.branch, isNull);
      expect(scan.gitStatus, isNull);
      expect(scan.privilege, isNull);
      expect(scan.completed, isTrue);
    });
  });
}
