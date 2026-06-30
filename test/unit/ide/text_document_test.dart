import 'package:omnyshell/src/application/client/ide/model/text_document.dart';
import 'package:test/test.dart';

void main() {
  group('editing', () {
    test('insert text advances the caret and sets dirty', () {
      final d = TextDocument.fromLines(['']);
      expect(d.dirty, isFalse);
      d.insert('hi');
      expect(d.lineAt(0), 'hi');
      expect(d.cursorCol, 2);
      expect(d.dirty, isTrue);
    });

    test('insert in the middle of a line', () {
      final d = TextDocument.fromLines(['ad'])
        ..cursorCol = 1
        ..insert('bc');
      expect(d.lineAt(0), 'abcd');
      expect(d.cursorCol, 3);
    });

    test('newline splits the current line', () {
      final d = TextDocument.fromLines(['abcd'])
        ..cursorCol = 2
        ..insertNewline();
      expect(d.lines, ['ab', 'cd']);
      expect(d.cursorRow, 1);
      expect(d.cursorCol, 0);
    });

    test('backspace within a line deletes the previous char', () {
      final d = TextDocument.fromLines(['abc'])
        ..cursorCol = 2
        ..backspace();
      expect(d.lineAt(0), 'ac');
      expect(d.cursorCol, 1);
    });

    test('backspace at line start joins with the previous line', () {
      final d = TextDocument.fromLines(['ab', 'cd'])
        ..cursorRow = 1
        ..cursorCol = 0
        ..backspace();
      expect(d.lines, ['abcd']);
      expect(d.cursorRow, 0);
      expect(d.cursorCol, 2);
    });

    test('delete-forward at line end joins the next line', () {
      final d = TextDocument.fromLines(['ab', 'cd'])
        ..cursorRow = 0
        ..cursorCol = 2
        ..deleteForward();
      expect(d.lines, ['abcd']);
    });

    test('backspace at the very start is a no-op', () {
      final d = TextDocument.fromLines(['abc']);
      d.backspace();
      expect(d.lines, ['abc']);
      expect(d.dirty, isFalse);
    });
  });

  group('cursor movement', () {
    test('left wraps to the end of the previous line', () {
      final d = TextDocument.fromLines(['ab', 'cd'])
        ..cursorRow = 1
        ..cursorCol = 0
        ..moveLeft();
      expect(d.cursorRow, 0);
      expect(d.cursorCol, 2);
    });

    test('right wraps to the start of the next line', () {
      final d = TextDocument.fromLines(['ab', 'cd'])
        ..cursorRow = 0
        ..cursorCol = 2
        ..moveRight();
      expect(d.cursorRow, 1);
      expect(d.cursorCol, 0);
    });

    test('vertical movement keeps the goal column across short lines', () {
      final d = TextDocument.fromLines(['longline', 'x', 'another'])
        ..moveTo(0, 6);
      d.moveDown(); // onto 'x' (length 1) -> clamps to col 1
      expect(d.cursorRow, 1);
      expect(d.cursorCol, 1);
      d.moveDown(); // onto 'another' -> restores goal column 6
      expect(d.cursorRow, 2);
      expect(d.cursorCol, 6);
    });

    test('home and end move within the line', () {
      final d = TextDocument.fromLines(['hello'])
        ..cursorCol = 2
        ..moveEnd();
      expect(d.cursorCol, 5);
      d.moveHome();
      expect(d.cursorCol, 0);
    });
  });

  group('serialisation', () {
    test('toText preserves the trailing newline and EOL', () {
      final d = TextDocument.fromLines(['a', 'b'], eol: '\n');
      expect(d.toText(), 'a\nb\n');
    });

    test('toText without a final newline', () {
      final d = TextDocument.fromLines(['a', 'b'], hadFinalNewline: false);
      expect(d.toText(), 'a\nb');
    });

    test('CRLF EOL is used when joining', () {
      final d = TextDocument.fromLines(['a', 'b'], eol: '\r\n');
      expect(d.toText(), 'a\r\nb\r\n');
    });
  });
}
