import 'package:omnyshell/src/application/client/ide/tui/screen_buffer.dart';
import 'package:omnyshell/src/application/client/ide/tui/style.dart';
import 'package:test/test.dart';

void main() {
  group('ScreenBuffer drawing', () {
    test('drawText clips to the row and respects maxWidth', () {
      final buf = ScreenBuffer(5, 1);
      final end = buf.drawText(0, 0, 'hello world', Style.none, maxWidth: 5);
      expect(end, 5);
      expect(
        [for (var x = 0; x < 5; x++) buf.cellAt(x, 0).char].join(),
        'hello',
      );
    });

    test('out-of-bounds writes are ignored', () {
      final buf = ScreenBuffer(3, 1);
      buf.setCell(-1, 0, 'x', Style.none);
      buf.setCell(3, 0, 'y', Style.none);
      buf.drawText(2, 0, 'abc', Style.none);
      expect(buf.cellAt(2, 0).char, 'a');
    });

    test('fillRect fills the clipped region', () {
      final buf = ScreenBuffer(4, 4);
      buf.fillRect(1, 1, 2, 2, '#', Style.none);
      expect(buf.cellAt(0, 0).char, ' ');
      expect(buf.cellAt(1, 1).char, '#');
      expect(buf.cellAt(2, 2).char, '#');
      expect(buf.cellAt(3, 3).char, ' ');
    });

    test('control characters paint as U+FFFD, never reaching the output', () {
      // e.g. a hostile node's hostname: clear screen, set title, ring bell.
      const hostile = '\x1b[2J\x1b]0;pwn\x07\x9b31m\x7f';
      final buf = ScreenBuffer(30, 1)
        ..drawText(0, 0, hostile, Style.none)
        ..setCell(29, 0, '\x1b', Style.none);
      final out = buf.renderDiff(null);
      // Strip the renderer's own cursor/SGR sequences, then nothing from the
      // text may remain that a terminal would act on.
      final painted = out
          .replaceAll(RegExp(r'\x1b\[\d+;\d+H'), '')
          .replaceAll(RegExp(r'\x1b\[[\d;]*m'), '');
      expect(painted, isNot(matches(RegExp(r'[\x00-\x1f\x7f-\x9f]'))));
      expect(buf.cellAt(0, 0).char, '\u{FFFD}'); // the ESC
      expect(buf.cellAt(1, 0).char, '['); // the rest is inert text
      expect(buf.cellAt(29, 0).char, '\u{FFFD}');
    });

    test('a TAB still paints as a space', () {
      final buf = ScreenBuffer(3, 1)..drawText(0, 0, 'a\tb', Style.none);
      expect([for (var x = 0; x < 3; x++) buf.cellAt(x, 0).char].join(), 'a b');
    });
  });

  group('renderDiff', () {
    test('a full first frame positions the cursor and paints text', () {
      final buf = ScreenBuffer(3, 1)..drawText(0, 0, 'abc', Style.none);
      final out = buf.renderDiff(null);
      expect(out, contains('\x1b[1;1H'));
      expect(out, contains('abc'));
    });

    test('an identical frame produces no output', () {
      final a = ScreenBuffer(3, 1)..drawText(0, 0, 'abc', Style.none);
      final b = ScreenBuffer(3, 1)..drawText(0, 0, 'abc', Style.none);
      expect(b.renderDiff(a), isEmpty);
    });

    test('only the changed run is repainted', () {
      final a = ScreenBuffer(5, 1)..drawText(0, 0, 'abcde', Style.none);
      final b = ScreenBuffer(5, 1)..drawText(0, 0, 'abXde', Style.none);
      final out = b.renderDiff(a);
      // Cursor jumps to column 3 (1-based) and writes just 'X'.
      expect(out, contains('\x1b[1;3H'));
      expect(out, contains('X'));
      expect(out, isNot(contains('abc')));
    });

    test('a size change forces a full repaint', () {
      final a = ScreenBuffer(3, 1)..drawText(0, 0, 'abc', Style.none);
      final b = ScreenBuffer(4, 1)..drawText(0, 0, 'abcd', Style.none);
      expect(b.renderDiff(a), contains('abcd'));
    });

    test('emits a style escape only when the style changes', () {
      const red = Style(fg: Color.red);
      final buf = ScreenBuffer(4, 1)
        ..setCell(0, 0, 'a', red)
        ..setCell(1, 0, 'b', red)
        ..setCell(2, 0, 'c', Style.none)
        ..setCell(3, 0, 'd', Style.none);
      final out = buf.renderDiff(null);
      // The red SGR should appear once for the 'ab' run.
      expect('\x1b[0;31m'.allMatches(out).length, 1);
    });
  });
}
