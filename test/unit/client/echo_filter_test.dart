import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/src/application/client/echo_filter.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
String _s(List<int> b) => utf8.decode(b);

void main() {
  const dialect = PowerShellDialect();
  final marker = CwdMarker('diag');
  final prompt = marker.promptSentinel;
  final init = dialect.sessionInitLine(marker);
  final full = dialect.fullMarker(marker);
  final command = dialect.wrapCommand(
    'Write-Output hello-omny',
    interactive: false,
    tail: dialect.pingMarker(marker),
  );

  late EchoFilter f;
  setUp(() => f = EchoFilter(prompt: prompt, initLine: init));

  test('the init line sets the sentinel prompt without containing it', () {
    expect(init, contains('function prompt'));
    // Written in halves: the init line's own echo cannot look like a prompt.
    expect(init, isNot(contains(prompt)));
    expect(prompt, isNot(contains(marker.token)));
  });

  group('the transcript PowerShell writes (both editions, recorded on CI)', () {
    // As `test/integration/powershell_pipe_test.dart` records it: the
    // default prompt before the init line, then the sentinel before every
    // later line read, each line echoed after it, `\n`-terminated.
    final primed =
        'PS C:\\Users\\runneradmin> $init\n'
        '$prompt$full\n'
        '${marker.token}C:\\Users\\runneradmin\t\t\troot\n';
    final ran = '$prompt$command\nhello-omny\r\n${marker.token}\n$prompt';

    test('leaves only the marker lines and the command\'s output', () {
      expect(
        _s(f.filter(_b(primed))),
        '${marker.token}C:\\Users\\runneradmin\t\t\troot\n',
      );
      f.commandCompleted();
      expect(_s(f.filter(_b(ran))), 'hello-omny\r\n${marker.token}\n');
    });

    test('byte by byte, too', () {
      String feed(String s) =>
          s.codeUnits.map((c) => _s(f.filter(Uint8List.fromList([c])))).join();
      expect(feed(primed), '${marker.token}C:\\Users\\runneradmin\t\t\troot\n');
      f.commandCompleted();
      expect(feed(ran), 'hello-omny\r\n${marker.token}\n');
    });
  });

  group('drops any line PowerShell reads, whoever sent it', () {
    test('a prompt written before the line, over a command boundary', () {
      expect(_s(f.filter(_b(prompt))), ''); // the client is idle
      f.commandCompleted();
      expect(_s(f.filter(_b('ls ; marker\nout\r\n'))), 'out\r\n');
    });

    test('keystrokes typed ahead, never sent as a command', () {
      f.commandCompleted();
      expect(_s(f.filter(_b('${prompt}dir\n$prompt\nout\n'))), 'out\n');
    });

    test('a line sent before the first prompt (a fast agent)', () {
      // Nothing to match against: the sentinel alone identifies it.
      expect(
        _s(f.filter(_b('PS C:\\> $init\n${prompt}Get-Date ; x\nTuesday\n'))),
        'Tuesday\n',
      );
    });
  });

  group('shows', () {
    setUp(() => f.commandCompleted()); // past the init line

    test('a nested pwsh\'s own prompt, at once', () {
      expect(_s(f.filter(_b(r'PS C:\Users\u> '))), r'PS C:\Users\u> ');
    });

    test('a program\'s own ">" prompt, at once', () {
      expect(_s(f.filter(_b('>'))), '>');
    });

    test('the sentinel in the middle of a line', () {
      expect(_s(f.filter(_b('x$prompt\n'))), 'x$prompt\n');
    });

    test('a line that only starts like the sentinel', () {
      final near = '${prompt.substring(0, 8)}NOPE';
      expect(_s(f.filter(_b(near.substring(0, 8)))), ''); // may still be it
      // It was not: the held start comes out with the rest of the line.
      expect(_s(f.filter(_b('NOPE\n'))), '$near\n');
    });

    test('lines starting with "PS" once the init line has run', () {
      expect(
        _s(f.filter(_b('PS C:\\> something\r\nPS rules\r\n'))),
        'PS C:\\> something\r\nPS rules\r\n',
      );
    });
  });

  group('the init line', () {
    test('its echo is dropped once, and only after the default prompt', () {
      expect(_s(f.filter(_b('$init\n'))), '$init\n'); // no prompt before it
      expect(_s(f.filter(_b('PS C:\\> $init\n'))), '');
      expect(_s(f.filter(_b('PS C:\\> $init\n'))), 'PS C:\\> $init\n');
    });

    test('a resumed session expects no init echo', () {
      final resumed = EchoFilter(prompt: prompt);
      // A default-prompt start is not held: no init echo is coming.
      expect(_s(resumed.filter(_b('PS'))), 'PS');
      expect(_s(resumed.filter(_b(' rules\n'))), ' rules\n');
      expect(_s(resumed.filter(_b('$prompt$command\nout\n'))), 'out\n');
    });
  });

  test('a chunk with no prompt passes through uncopied', () {
    f.commandCompleted();
    final chunk = _b('plain output\r\nmore\r\n');
    expect(identical(f.filter(chunk), chunk), isTrue);
  });
}
