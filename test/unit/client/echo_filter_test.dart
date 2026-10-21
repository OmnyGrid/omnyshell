import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/src/application/client/echo_filter.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
String _s(List<int> b) => utf8.decode(b);

void main() {
  late EchoFilter f;
  setUp(() => f = EchoFilter());

  group('drops', () {
    test('an echoed line and its CRLF, keeping the output', () {
      f.expect('ls ; marker');
      expect(
        _s(f.filter(_b('ls ; marker\r\n\r\nDirectory: C:\\\r\n'))),
        '\r\nDirectory: C:\\\r\n',
      );
    });

    test('a LF-terminated echo', () {
      f.expect('dir');
      expect(_s(f.filter(_b('dir\nout\n'))), 'out\n');
    });

    test('echoes in the order the lines were sent', () {
      f
        ..expect('init line')
        ..expect('marker line');
      expect(
        _s(f.filter(_b('init line\r\nmarker line\r\nTOKEN/c\n'))),
        'TOKEN/c\n',
      );
    });

    test('an echo after the default prompt, with the prompt', () {
      // Before the init line runs, PowerShell 5.1 still prints `PS …> `.
      f
        ..expect("function prompt { '' }")
        ..expect('marker line');
      expect(
        _s(
          f.filter(
            _b(
              "PS C:\\Users\\u> function prompt { '' }\r\n"
              'marker line\r\nTOKEN/c\n',
            ),
          ),
        ),
        'TOKEN/c\n',
      );
    });

    test('an echo after the continuation prompt', () {
      f.expect('ls ; marker');
      expect(_s(f.filter(_b('>> ls ; marker\r\nout\n'))), 'out\n');
    });

    test('a later echo even when an earlier one was missed', () {
      // The first echo did not come back recognisably (say, another code
      // page); the second must still be dropped, and the first forgotten.
      f
        ..expect('first')
        ..expect('second');
      expect(_s(f.filter(_b('fïrst\r\nsecond\r\nout\n'))), 'fïrst\r\nout\n');
      expect(_s(f.filter(_b('first\r\n'))), 'first\r\n');
    });

    test('an echo split across chunks', () {
      f.expect('ls ; marker');
      expect(_s(f.filter(_b('ls ; ma'))), '');
      expect(_s(f.filter(_b('rker\r'))), '');
      expect(_s(f.filter(_b('\nresult\n'))), 'result\n');
    });

    test('an echo whose prompt arrives in a chunk of its own', () {
      f.expect('cmd');
      expect(_s(f.filter(_b('PS C:\\> '))), '');
      expect(_s(f.filter(_b('cmd\r\nout\n'))), 'out\n');
    });

    test('an echo only once', () {
      f.expect('echo hi');
      expect(_s(f.filter(_b('echo hi\r\necho hi\r\n'))), 'echo hi\r\n');
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

    test('unrelated lines around the echo', () {
      f.expect('cmd');
      expect(_s(f.filter(_b('earlier\ncmd\r\nlater\n'))), 'earlier\nlater\n');
    });

    test('a line that ends with the echo after something not a prompt', () {
      f.expect('cmd');
      expect(_s(f.filter(_b('xcmd\n'))), 'xcmd\n');
      expect(_s(f.filter(_b('echo: cmd\n'))), 'echo: cmd\n');
    });

    test('a program\'s own "> " prompt, shown at once', () {
      f.expect('python');
      expect(_s(f.filter(_b('> '))), '> ');
    });

    test('everything, with nothing expected', () {
      expect(_s(f.filter(_b('anything\n'))), 'anything\n');
    });
  });

  group('holding back', () {
    test('held bytes come back when the command completes', () {
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
      // Whole lines are still checked.
      expect(_s(f.filter(_b('s\r\n'))), 's\r\n');
    });

    test('resumes as soon as an echo shows up again', () {
      f.expect('a');
      f.commandCompleted(); // nothing echoed
      expect(f.holdsPartialLines, isFalse);
      f.expect('b');
      expect(_s(f.filter(_b('b\r\nout\n'))), 'out\n'); // a whole-line echo
      expect(f.holdsPartialLines, isTrue);
      f
        ..commandCompleted()
        ..expect('c');
      expect(_s(f.filter(_b('c'))), ''); // held again
    });

    test('stays on for a shell that does echo', () {
      f.expect('a');
      f.filter(_b('a\r\n'));
      f.commandCompleted();
      expect(f.holdsPartialLines, isTrue);
    });
  });
}
