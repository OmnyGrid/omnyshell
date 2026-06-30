import 'dart:convert';

import 'package:omnyshell/src/application/client/ide/tui/key.dart';
import 'package:omnyshell/src/application/client/ide/tui/key_decoder.dart';
import 'package:test/test.dart';

void main() {
  late KeyDecoder d;
  setUp(() => d = KeyDecoder());

  List<KeyEvent> decodeStr(String s) => d.decode(s.codeUnits);

  group('printable & control', () {
    test('ASCII printable characters', () {
      expect(decodeStr('Ab1'), [
        KeyEvent.char(0x41),
        KeyEvent.char(0x62),
        KeyEvent.char(0x31),
      ]);
    });

    test('Enter (CR and LF), Tab and Backspace', () {
      expect(d.decode([0x0d]), [const KeyEvent(KeyType.enter)]);
      expect(d.decode([0x0a]), [const KeyEvent(KeyType.enter)]);
      expect(d.decode([0x09]), [const KeyEvent(KeyType.tab)]);
      expect(d.decode([0x7f]), [const KeyEvent(KeyType.backspace)]);
      expect(d.decode([0x08]), [const KeyEvent(KeyType.backspace)]);
    });

    test('Ctrl-letters map to lowercase', () {
      expect(d.decode([0x13]), [KeyEvent.ctrl('s')]); // Ctrl-S
      expect(d.decode([0x11]), [KeyEvent.ctrl('q')]); // Ctrl-Q
      expect(d.decode([0x02]), [KeyEvent.ctrl('b')]); // Ctrl-B
    });
  });

  group('escape sequences', () {
    test('arrow keys (CSI)', () {
      expect(decodeStr('\x1b[A'), [const KeyEvent(KeyType.up)]);
      expect(decodeStr('\x1b[B'), [const KeyEvent(KeyType.down)]);
      expect(decodeStr('\x1b[C'), [const KeyEvent(KeyType.right)]);
      expect(decodeStr('\x1b[D'), [const KeyEvent(KeyType.left)]);
    });

    test('SS3 arrows (application cursor mode)', () {
      expect(decodeStr('\x1bOA'), [const KeyEvent(KeyType.up)]);
    });

    test('Home/End in both letter forms', () {
      expect(decodeStr('\x1b[H'), [const KeyEvent(KeyType.home)]);
      expect(decodeStr('\x1b[F'), [const KeyEvent(KeyType.end)]);
      expect(decodeStr('\x1b[1~'), [const KeyEvent(KeyType.home)]);
      expect(decodeStr('\x1b[4~'), [const KeyEvent(KeyType.end)]);
    });

    test('Delete, PageUp, PageDown (tilde finals)', () {
      expect(decodeStr('\x1b[3~'), [const KeyEvent(KeyType.delete)]);
      expect(decodeStr('\x1b[5~'), [const KeyEvent(KeyType.pageUp)]);
      expect(decodeStr('\x1b[6~'), [const KeyEvent(KeyType.pageDown)]);
    });

    test('Shift-Tab (CSI Z)', () {
      expect(decodeStr('\x1b[Z'), [const KeyEvent(KeyType.backTab)]);
    });

    test('modified arrows ignore parameters', () {
      // Ctrl-Left arrives as ESC[1;5D — still a left arrow to us.
      expect(decodeStr('\x1b[1;5D'), [const KeyEvent(KeyType.left)]);
    });

    test('a lone ESC flushes to Escape', () {
      expect(d.decode([0x1b]), isEmpty); // incomplete, buffered
      expect(d.flush(), [const KeyEvent(KeyType.escape)]);
    });
  });

  group('chunk boundaries', () {
    test('an escape sequence split across chunks decodes once complete', () {
      expect(d.decode([0x1b]), isEmpty);
      expect(d.decode([0x5b]), isEmpty);
      expect(d.decode([0x41]), [const KeyEvent(KeyType.up)]);
    });

    test('a UTF-8 character split across chunks decodes once complete', () {
      final bytes = utf8.encode('é'); // 2 bytes
      expect(d.decode([bytes[0]]), isEmpty);
      expect(d.decode([bytes[1]]), [KeyEvent.char('é'.runes.first)]);
    });
  });
}
