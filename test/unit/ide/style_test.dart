import 'package:omnyshell/src/application/client/ide/tui/style.dart';
import 'package:test/test.dart';

void main() {
  group('Color.sgr params', () {
    test('named colours use the 30-37 / 90-97 ranges', () {
      expect(const Style(fg: Color.red).sgr, '\x1b[0;31m');
      expect(const Style(fg: Color.brightRed).sgr, '\x1b[0;91m');
      expect(const Style(bg: Color.blue).sgr, '\x1b[0;44m');
    });

    test('indexed colours use the 38;5;n / 48;5;n form', () {
      expect(const Style(fg: Color.indexed(81)).sgr, '\x1b[0;38;5;81m');
      expect(const Style(bg: Color.indexed(235)).sgr, '\x1b[0;48;5;235m');
    });
  });

  group('Style.sgr', () {
    test('starts from a reset and includes every attribute', () {
      const s = Style(
        fg: Color.indexed(204),
        bold: true,
        italic: true,
        underline: true,
        dim: true,
        reverse: true,
      );
      expect(s.sgr, '\x1b[0;1;2;3;4;7;38;5;204m');
    });

    test('the default style is a bare reset', () {
      expect(Style.none.sgr, '\x1b[0m');
    });

    test('copyWith overrides only the named fields', () {
      const base = Style(fg: Color.white, bold: true);
      final out = base.copyWith(fg: Color.red, italic: true);
      expect(out.fg, Color.red);
      expect(out.bold, isTrue);
      expect(out.italic, isTrue);
    });
  });

  group('equality', () {
    test('styles compare by value', () {
      expect(
        const Style(fg: Color.indexed(1), bold: true),
        const Style(fg: Color.indexed(1), bold: true),
      );
      expect(
        const Style(fg: Color.indexed(1)),
        isNot(const Style(fg: Color.indexed(2))),
      );
    });
  });
}
