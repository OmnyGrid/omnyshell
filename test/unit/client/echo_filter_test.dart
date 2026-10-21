import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/src/application/client/echo_filter.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
String _s(List<int> b) => utf8.decode(b);

void main() {
  late EchoFilter f;
  setUp(() => f = EchoFilter());

  group('the transcript PowerShell writes (both editions, recorded on CI)', () {
    // As `test/integration/powershell_pipe_test.dart` recorded it from
    // Windows PowerShell 5.1 and PowerShell 7: the prompt before each line
    // read, the line echoed after it, `\n`-terminated.
    const dialect = PowerShellDialect();
    final marker = CwdMarker('diag');
    final init = dialect.initLine!;
    final full = dialect.fullMarker(marker);
    final command = dialect.wrapCommand(
      'Write-Output hello-omny',
      interactive: false,
      tail: dialect.pingMarker(marker),
    );
    final primed =
        'PS C:\\Users\\runneradmin> $init\n'
        'PS>$full\n'
        '${marker.token}C:\\Users\\runneradmin\t\t\troot\n';
    final ran = 'PS>$command\nhello-omny\r\n${marker.token}\nPS>';

    test('leaves only the marker lines and the command\'s output', () {
      f
        ..expect(init)
        ..expect(full);
      expect(
        _s(f.filter(_b(primed))),
        '${marker.token}C:\\Users\\runneradmin\t\t\troot\n',
      );
      f
        ..commandCompleted()
        ..expect(command);
      expect(_s(f.filter(_b(ran))), 'hello-omny\r\n${marker.token}\n');
      // The prompt for the next line is held, and kept over the boundary.
      expect(_s(f.commandCompleted()), isEmpty);
    });

    test('byte by byte, too', () {
      String feed(String s) =>
          s.codeUnits.map((c) => _s(f.filter(Uint8List.fromList([c])))).join();
      f
        ..expect(init)
        ..expect(full);
      // Feed as bytes: the transcript is ASCII.
      expect(feed(primed), '${marker.token}C:\\Users\\runneradmin\t\t\troot\n');
      f
        ..commandCompleted()
        ..expect(command);
      expect(feed(ran), 'hello-omny\r\n${marker.token}\n');
    });

    test('the next prompt, sent before the line, joins its echo', () {
      // `PS>` arrives while the client is idle; the line is sent after.
      expect(_s(f.filter(_b('PS>'))), '');
      f.commandCompleted(); // a boundary in between: the prompt is kept
      f.expect('ls');
      expect(_s(f.filter(_b('ls\nout\r\n'))), 'out\r\n');
    });
  });

  group('drops', () {
    test('a bare echo with CRLF or LF', () {
      f
        ..expect('a')
        ..expect('b');
      expect(_s(f.filter(_b('a\r\nb\nout\n'))), 'out\n');
    });

    test('an echo after the continuation prompt', () {
      f.expect('ls ; marker');
      expect(_s(f.filter(_b('>> ls ; marker\nout\n'))), 'out\n');
    });

    test('a later echo even when an earlier one was missed', () {
      // The first echo did not come back recognisably (another code page):
      // the second must still be dropped, and the first forgotten.
      f
        ..expect('first')
        ..expect('second');
      expect(_s(f.filter(_b('PS>fïrst\nPS>second\nout\n'))), 'PS>fïrst\nout\n');
      expect(_s(f.filter(_b('first\n'))), 'first\n');
    });

    test('an echo only once', () {
      f.expect('echo hi');
      expect(_s(f.filter(_b('PS>echo hi\necho hi\r\n'))), 'echo hi\r\n');
    });
  });

  group('keeps', () {
    test('output that only starts like the echo', () {
      f.expect('ls ; marker');
      expect(
        _s(f.filter(_b('ls ; something else\n'))),
        'ls ; something else\n',
      );
    });

    test('a line ending with the echo after something not a prompt', () {
      f.expect('cmd');
      expect(_s(f.filter(_b('xcmd\necho: cmd\n'))), 'xcmd\necho: cmd\n');
    });

    test('a mid-line occurrence', () {
      f.expect('cmd');
      expect(_s(f.filter(_b('partial'))), 'partial');
      expect(_s(f.filter(_b('PS>cmd\n'))), 'PS>cmd\n');
    });

    test('output lines that start with "PS"', () {
      expect(
        _s(f.filter(_b('PS rules\r\nPSScript\r\n'))),
        'PS rules\r\nPSScript\r\n',
      );
    });

    test('a program\'s own "> " prompt, shown at once', () {
      f.expect('python');
      expect(_s(f.filter(_b('> '))), '> ');
    });

    test('everything, with nothing expected and no prompt', () {
      expect(_s(f.filter(_b('anything\n'))), 'anything\n');
    });
  });

  group('holding back', () {
    test('a partial echo comes back when the command completes', () {
      f.expect('ls ; marker');
      expect(_s(f.filter(_b('ls'))), ''); // could be the echo
      expect(_s(f.commandCompleted()), 'ls');
    });

    test('stops for a shell that did not echo the last command', () {
      f.expect('ls ; marker');
      expect(_s(f.filter(_b('result\n'))), 'result\n');
      f.commandCompleted(); // nothing echoed
      expect(f.holdsPartialLines, isFalse);
      f.expect('ls');
      expect(_s(f.filter(_b('l'))), 'l'); // not held
      expect(_s(f.filter(_b('s\r\n'))), 's\r\n');
    });

    test('resumes as soon as an echo shows up again', () {
      f.expect('a');
      f.commandCompleted(); // nothing echoed
      expect(f.holdsPartialLines, isFalse);
      f.expect('b');
      expect(_s(f.filter(_b('PS>b\nout\n'))), 'out\n');
      expect(f.holdsPartialLines, isTrue);
    });

    test('a prompt is held even for a shell taken not to echo', () {
      f.expect('a');
      f.commandCompleted(); // nothing echoed
      expect(_s(f.filter(_b('PS>'))), '');
    });
  });
}
