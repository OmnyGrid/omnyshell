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

  group('LoneEscapeTimer', () {
    late List<KeyEvent> delivered;
    late LoneEscapeTimer timer;
    setUp(() {
      delivered = [];
      timer = LoneEscapeTimer(d, delivered.addAll);
    });
    tearDown(() => timer.cancel());

    Future<void> waitOut() =>
        Future<void>.delayed(KeyDecoder.escapeTimeout * 2);

    test('delivers a lone ESC as Escape once nothing follows it', () async {
      expect(d.decode([0x1b]), isEmpty);
      expect(d.hasPendingEscape, isTrue);
      timer.arm();
      expect(delivered, isEmpty); // not before the timeout
      await waitOut();
      expect(delivered, [const KeyEvent(KeyType.escape)]);
      expect(d.hasPendingEscape, isFalse);
    });

    test(
      'more input before the timeout completes the sequence instead',
      () async {
        d.decode([0x1b]);
        timer.arm();
        timer.cancel(); // the next chunk arrived
        expect(d.decode([0x5b, 0x41]), [const KeyEvent(KeyType.up)]);
        timer.arm(); // nothing pending now
        await waitOut();
        expect(delivered, isEmpty);
      },
    );

    test('arm does nothing when no lone ESC is buffered', () async {
      d.decode('ab'.codeUnits);
      timer.arm();
      await waitOut();
      expect(delivered, isEmpty);
    });
  });

  group('mouse wheel', () {
    test('SGR wheel up/down carry the 0-based pointer cell', () {
      expect(decodeStr('\x1b[<64;10;5M'), [
        KeyEvent.wheel(up: true, x: 9, y: 4),
      ]);
      expect(decodeStr('\x1b[<65;1;1M'), [
        KeyEvent.wheel(up: false, x: 0, y: 0),
      ]);
    });

    test('modifier bits still scroll (Ctrl+wheel down = 65+16)', () {
      expect(decodeStr('\x1b[<81;3;4M'), [
        KeyEvent.wheel(up: false, x: 2, y: 3),
      ]);
    });

    test('clicks, releases and horizontal wheel emit nothing at all', () {
      // Not even KeyType.unknown: apps treat any key as a keypress (clearing
      // the status message, disarming Ctrl-Q), which a click must not do.
      expect(decodeStr('\x1b[<0;3;4M\x1b[<0;3;4m\x1b[<66;3;4Mx'), [
        KeyEvent.char(0x78),
      ]);
    });

    test('a malformed SGR report is dropped, never read as a key', () {
      expect(decodeStr('\x1b[<64;3M'), isEmpty);
    });

    test('an SGR report split across chunks completes on the next chunk', () {
      expect(decodeStr('\x1b[<65;12'), isEmpty);
      expect(decodeStr(';7Mx'), [
        KeyEvent.wheel(up: false, x: 11, y: 6),
        KeyEvent.char(0x78),
      ]);
    });

    test(
      'legacy X10 reports are consumed whole (wheel up at 1-based 10,5)',
      () {
        final m = KeyDecoder(mouseReports: true);
        // ESC [ M, then button/col/row each offset by 32: 64+32, 10+32, 5+32.
        expect(m.decode([0x1b, 0x5b, 0x4d, 96, 42, 37]), [
          KeyEvent.wheel(up: true, x: 9, y: 4),
        ]);
        // A click's payload bytes (here printable) must not become typed text.
        expect(m.decode([0x1b, 0x5b, 0x4d, 32, 0x61, 0x62, 0x7a]), [
          KeyEvent.char(0x7a),
        ]);
      },
    );

    test('a legacy report split before its payload waits for it', () {
      final m = KeyDecoder(mouseReports: true);
      expect(m.decode([0x1b, 0x5b, 0x4d, 97]), isEmpty);
      expect(m.decode([33, 33]), [KeyEvent.wheel(up: false, x: 0, y: 0)]);
    });

    test('without mouseReports, ESC [ M is one key and spares the next', () {
      // e.g. F1 on a cons25 keymap: the following keystrokes stay keys.
      expect(d.decode([0x1b, 0x5b, 0x4d, 0x61, 0x62, 0x63]), [
        const KeyEvent(KeyType.unknown),
        KeyEvent.char(0x61),
        KeyEvent.char(0x62),
        KeyEvent.char(0x63),
      ]);
    });
  });
}
