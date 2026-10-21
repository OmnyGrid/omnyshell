import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/src/application/client/echo_filter.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
String _s(List<int> b) => utf8.decode(b);

void main() {
  late EchoFilter f;
  setUp(() => f = EchoFilter());

  test('drops an echoed line and its CRLF, keeps the output', () {
    f.expect('ls ; marker');
    expect(
      _s(f.filter(_b('ls ; marker\r\n\r\nDirectory: C:\\\r\n'))),
      '\r\nDirectory: C:\\\r\n',
    );
  });

  test('drops a LF-terminated echo too', () {
    f.expect('dir');
    expect(_s(f.filter(_b('dir\nout\n'))), 'out\n');
  });

  test('drops echoes in the order the lines were sent', () {
    f
      ..expect('init line')
      ..expect('marker line');
    expect(
      _s(f.filter(_b('init line\r\nmarker line\r\nTOKEN/c\n'))),
      'TOKEN/c\n',
    );
  });

  test('recognises an echo split across chunks', () {
    f.expect('ls ; marker');
    expect(_s(f.filter(_b('ls ; ma'))), '');
    expect(_s(f.filter(_b('rker\r'))), '');
    expect(_s(f.filter(_b('\nresult\n'))), 'result\n');
  });

  test('passes output that only starts like the echo', () {
    f.expect('ls ; marker');
    expect(_s(f.filter(_b('ls ; something else\n'))), 'ls ; something else\n');
  });

  test('finds the echo after unrelated whole lines', () {
    f.expect('cmd');
    expect(_s(f.filter(_b('earlier\ncmd\r\nlater\n'))), 'earlier\nlater\n');
  });

  test('matches only at the start of a line', () {
    f.expect('cmd');
    expect(_s(f.filter(_b('xcmd\n'))), 'xcmd\n');
  });

  test('drops an echo only once', () {
    f.expect('echo hi');
    expect(_s(f.filter(_b('echo hi\r\necho hi\r\n'))), 'echo hi\r\n');
  });

  test('held bytes come back when the command completes', () {
    f.expect('ls ; marker');
    expect(_s(f.filter(_b('ls'))), ''); // could be the echo
    expect(_s(f.commandCompleted()), 'ls');
  });

  test('turns itself off for a shell that never echoes', () {
    f.expect('ls ; marker');
    expect(_s(f.filter(_b('result\n'))), 'result\n');
    f.commandCompleted(); // no echo seen for the first command
    expect(f.disabled, isTrue);
    // Now nothing is held, even output that looks like a sent line.
    f.expect('ls');
    expect(_s(f.filter(_b('l'))), 'l');
  });

  test('stays on for a shell that does echo', () {
    f.expect('a');
    f.filter(_b('a\r\n'));
    f.commandCompleted();
    expect(f.disabled, isFalse);
    f.expect('b');
    expect(_s(f.filter(_b('b\r\nout\n'))), 'out\n');
  });

  test('with nothing expected, passes everything through', () {
    expect(_s(f.filter(_b('anything\n'))), 'anything\n');
  });
}
