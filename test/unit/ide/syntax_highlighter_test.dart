import 'package:omnyshell/src/application/client/ide/syntax/dart_highlighter.dart';
import 'package:omnyshell/src/application/client/ide/syntax/highlighter.dart';
import 'package:omnyshell/src/application/client/ide/syntax/highlighter_registry.dart';
import 'package:omnyshell/src/application/client/ide/syntax/json_highlighter.dart';
import 'package:omnyshell/src/application/client/ide/syntax/markdown_highlighter.dart';
import 'package:omnyshell/src/application/client/ide/syntax/plain_highlighter.dart';
import 'package:omnyshell/src/application/client/ide/syntax/yaml_highlighter.dart';
import 'package:omnyshell/src/application/client/ide/tui/style.dart';
import 'package:test/test.dart';

// A theme that maps every token type to a distinct style, so a run's style
// reverse-maps to exactly one [TokenType] in [typeOfRun]. (The shipped
// [TokenTheme.dark] deliberately shares colours between some token types, which
// is fine for rendering but ambiguous for this reverse lookup.)
final theme = TokenTheme({
  for (final t in TokenType.values) t: Style(fg: Color.indexed(t.index + 1)),
});

/// The token type whose styled run covers [text] in [runs] (asserts exactly one
/// run has that text).
TokenType typeOfRun(List<StyledRun> runs, String text) {
  final run = runs.firstWhere(
    (r) => r.text == text,
    orElse: () => throw StateError(
      'no run "$text" in ${runs.map((r) => r.text).toList()}',
    ),
  );
  for (final t in TokenType.values) {
    if (theme.styleFor(t) == run.style) return t;
  }
  throw StateError('unknown style for "$text"');
}

void main() {
  group('DartHighlighter', () {
    const h = DartHighlighter();
    LineHighlight hl(String line, [HighlightState s = HighlightState.none]) =>
        h.highlight(line, s, theme);

    test('runs concatenate back to the original line', () {
      final r = hl('  final x = foo(1);');
      expect(r.text, '  final x = foo(1);');
    });

    test('keywords, types, calls, numbers and strings', () {
      final r = hl("final List items = parse('hi', 42);").runs;
      expect(typeOfRun(r, 'final'), TokenType.keyword);
      expect(typeOfRun(r, 'List'), TokenType.type);
      expect(typeOfRun(r, 'parse'), TokenType.function);
      expect(typeOfRun(r, "'hi'"), TokenType.string);
      expect(typeOfRun(r, '42'), TokenType.number);
    });

    test('line comments run to end of line', () {
      final r = hl('x = 1; // trailing').runs;
      expect(typeOfRun(r, '// trailing'), TokenType.comment);
    });

    test('annotations are attributes', () {
      final r = hl('@override').runs;
      expect(typeOfRun(r, '@override'), TokenType.attribute);
    });

    test('block comments carry across lines', () {
      final first = hl('a /* open');
      expect(first.next, isNot(HighlightState.none));
      final second = hl('still comment', first.next);
      expect(typeOfRun(second.runs, 'still comment'), TokenType.comment);
      final third = hl('end */ code', second.next);
      expect(third.next, HighlightState.none);
      expect(typeOfRun(third.runs, 'end */'), TokenType.comment);
    });

    test('triple-quoted strings carry across lines', () {
      final first = hl("var s = '''start");
      expect(first.next, isNot(HighlightState.none));
      final second = hl('middle', first.next);
      expect(typeOfRun(second.runs, 'middle'), TokenType.string);
      final third = hl("end''';", second.next);
      expect(third.next, HighlightState.none);
    });
  });

  group('JsonHighlighter', () {
    const h = JsonHighlighter();
    test('object keys are properties and values are strings', () {
      final r = h
          .highlight('  "name": "omnyShell",', HighlightState.none, theme)
          .runs;
      expect(typeOfRun(r, '"name"'), TokenType.property);
      expect(typeOfRun(r, '"omnyShell"'), TokenType.string);
    });

    test('literals and numbers', () {
      final r = h
          .highlight('"on": true, "n": 42', HighlightState.none, theme)
          .runs;
      expect(typeOfRun(r, 'true'), TokenType.constant);
      expect(typeOfRun(r, '42'), TokenType.number);
    });
  });

  group('YamlHighlighter', () {
    const h = YamlHighlighter();
    LineHighlight hl(String line) =>
        h.highlight(line, HighlightState.none, theme);

    test('mapping key, value and inline comment', () {
      final r = hl('name: omnyshell # the package').runs;
      expect(typeOfRun(r, 'name'), TokenType.property);
      expect(typeOfRun(r, '# the package'), TokenType.comment);
    });

    test('full-line comment', () {
      final r = hl('  # a note').runs;
      expect(typeOfRun(r, '# a note'), TokenType.comment);
    });

    test('sequence markers and constants', () {
      final r = hl('  - true').runs;
      expect(typeOfRun(r, '-'), TokenType.listMarker);
      expect(typeOfRun(r, 'true'), TokenType.constant);
    });

    test('numbers in values', () {
      final r = hl('count: 1234').runs;
      expect(typeOfRun(r, '1234'), TokenType.number);
    });

    test('a colon inside a URL value is not treated as a key break', () {
      final line = hl('repo: https://example.com');
      expect(typeOfRun(line.runs, 'repo'), TokenType.property);
      expect(line.text, 'repo: https://example.com');
    });
  });

  group('MarkdownHighlighter', () {
    const h = MarkdownHighlighter();
    LineHighlight hl(String line, [HighlightState s = HighlightState.none]) =>
        h.highlight(line, s, theme);

    test('headings, blockquotes and list markers', () {
      expect(typeOfRun(hl('# Title').runs, '# Title'), TokenType.heading);
      expect(typeOfRun(hl('> quote').runs, '> quote'), TokenType.blockquote);
      expect(typeOfRun(hl('- item').runs, '- '), TokenType.listMarker);
    });

    test('inline code, strong, emphasis and links', () {
      expect(
        typeOfRun(hl('use `code` here').runs, '`code`'),
        TokenType.codeSpan,
      );
      expect(typeOfRun(hl('a **bold** b').runs, '**bold**'), TokenType.strong);
      expect(typeOfRun(hl('a *em* b').runs, '*em*'), TokenType.emphasis);
      expect(
        typeOfRun(hl('see [docs](http://x) ok').runs, '[docs](http://x)'),
        TokenType.link,
      );
    });

    test('fenced code blocks carry across lines', () {
      final open = hl('```dart');
      expect(open.next, isNot(HighlightState.none));
      final body = hl('final x = 1;', open.next);
      expect(typeOfRun(body.runs, 'final x = 1;'), TokenType.codeSpan);
      final close = hl('```', body.next);
      expect(close.next, HighlightState.none);
    });
  });

  group('PlainHighlighter', () {
    test('emits a single plain run', () {
      final r = const PlainHighlighter().highlight(
        'anything goes',
        HighlightState.none,
        theme,
      );
      expect(r.runs.length, 1);
      expect(r.runs.first.style, theme.styleFor(TokenType.plain));
    });
  });

  group('HighlighterRegistry', () {
    final reg = HighlighterRegistry();
    test('selects by extension', () {
      expect(reg.forPath('lib/foo.dart').language, 'Dart');
      expect(reg.forPath('pubspec.yaml').language, 'YAML');
      expect(reg.forPath('config.yml').language, 'YAML');
      expect(reg.forPath('data.json').language, 'JSON');
      expect(reg.forPath('README.md').language, 'Markdown');
    });

    test('unknown extensions fall back to plain text', () {
      expect(reg.forPath('mystery.xyz').language, 'Text');
      expect(reg.forPath('Makefile').language, 'Text');
    });
  });
}
