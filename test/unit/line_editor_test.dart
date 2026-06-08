import 'dart:async';
import 'dart:convert';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

void main() {
  group('LineEditor passthrough', () {
    test('forwards raw bytes to onRaw and does not deliver lines', () async {
      final input = StreamController<List<int>>();
      final lines = <String>[];
      final raw = <int>[];

      final editor = LineEditor(
        input: input.stream,
        output: (_) {},
        history: CommandHistory.inMemory(),
        interactive: true,
        // Avoid touching real terminal modes in the test.
        setRawMode: (_) {},
        onLine: (line) => lines.add(line),
        onRaw: raw.addAll,
      );
      editor.start();

      editor.setPassthrough(true);
      // Includes a CR which would normally commit a line in edit mode.
      input.add(utf8.encode('hi\r\x1b[A'));
      await Future<void>.delayed(Duration.zero);

      expect(raw, utf8.encode('hi\r\x1b[A'));
      expect(lines, isEmpty);

      await input.close();
      await editor.close();
    });

    test('interrupt() in line mode discards the line and notifies', () async {
      final input = StreamController<List<int>>();
      final lines = <String>[];
      final out = StringBuffer();
      var interrupts = 0;

      final editor = LineEditor(
        input: input.stream,
        output: out.write,
        history: CommandHistory.inMemory(),
        interactive: true,
        setRawMode: (_) {},
        onLine: (line) => lines.add(line),
        onInterrupt: () => interrupts++,
      );
      editor.start();

      input.add(utf8.encode('partial'));
      await Future<void>.delayed(Duration.zero);
      editor.interrupt(); // SIGINT-style, out-of-band
      await Future<void>.delayed(Duration.zero);

      expect(interrupts, 1);
      expect(out.toString(), contains('^C'));
      // The discarded line is not delivered; a following Enter yields an empty
      // line, proving the buffer was cleared.
      input.add(utf8.encode('\n'));
      await Future<void>.delayed(Duration.zero);
      expect(lines, ['']);

      await input.close();
      await editor.close();
    });

    test('interrupt() in passthrough only notifies (no ^C echo)', () async {
      final input = StreamController<List<int>>();
      final out = StringBuffer();
      var interrupts = 0;

      final editor = LineEditor(
        input: input.stream,
        output: out.write,
        history: CommandHistory.inMemory(),
        interactive: true,
        setRawMode: (_) {},
        onLine: (_) {},
        onInterrupt: () => interrupts++,
        onRaw: (_) {},
      );
      editor.start();
      editor.setPassthrough(true);

      editor.interrupt();
      await Future<void>.delayed(Duration.zero);

      expect(interrupts, 1);
      expect(out.toString(), isNot(contains('^C')));

      await input.close();
      await editor.close();
    });

    test('resumes line editing after passthrough is turned off', () async {
      final input = StreamController<List<int>>();
      final lines = <String>[];
      final raw = <int>[];

      final editor = LineEditor(
        input: input.stream,
        output: (_) {},
        history: CommandHistory.inMemory(),
        interactive: true,
        setRawMode: (_) {},
        onLine: (line) => lines.add(line),
        onRaw: raw.addAll,
      );
      editor.start();

      editor.setPassthrough(true);
      input.add(utf8.encode('xx'));
      await Future<void>.delayed(Duration.zero);

      editor.setPassthrough(false);
      // The previous passthrough bytes must not leak into the next line.
      input.add(utf8.encode('ls\n'));
      await Future<void>.delayed(Duration.zero);

      expect(raw, utf8.encode('xx'));
      expect(lines, ['ls']);

      await input.close();
      await editor.close();
    });
  });

  group('LineEditor completion', () {
    // Drives an editor through typing [typed], a Tab, then Enter, returning the
    // committed line and everything written to the output.
    Future<({String line, String output})> complete(
      String typed,
      Future<List<String>> Function(String word, bool isCommand) onComplete,
    ) async {
      final input = StreamController<List<int>>();
      final out = StringBuffer();
      final lines = <String>[];
      final editor = LineEditor(
        input: input.stream,
        output: out.write,
        history: CommandHistory.inMemory(),
        interactive: true,
        setRawMode: (_) {},
        onLine: lines.add,
        onComplete: onComplete,
      );
      editor.start();
      input.add(utf8.encode(typed));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      input.add([0x09]); // Tab
      await Future<void>.delayed(const Duration(milliseconds: 10));
      input.add([0x0d]); // Enter
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await input.close();
      await editor.close();
      return (line: lines.single, output: out.toString());
    }

    test('inserts a single candidate with a trailing space', () async {
      final r = await complete('fi', (w, _) async => ['file.txt']);
      expect(r.line, 'file.txt ');
    });

    test('a single directory candidate gets no trailing space', () async {
      final r = await complete('su', (w, _) async => ['sub/']);
      expect(r.line, 'sub/');
    });

    test('completes the longest common prefix of several candidates', () async {
      final r = await complete('al', (w, _) async => ['album1', 'album2']);
      expect(r.line, 'album');
    });

    test('lists candidates when no further prefix can be added', () async {
      final r = await complete('al', (w, _) async => ['alpha', 'album']);
      expect(r.line, 'al'); // line unchanged
      expect(r.output, contains('alpha'));
      expect(r.output, contains('album'));
    });

    test('rings the bell when there is nothing to complete', () async {
      final r = await complete('zz', (w, _) async => const []);
      expect(r.line, 'zz');
      expect(r.output, contains('\x07'));
    });

    test('passes the word and command position to the callback', () async {
      String? seenWord;
      bool? seenIsCommand;
      await complete('git sta', (w, isCmd) async {
        seenWord = w;
        seenIsCommand = isCmd;
        return const [];
      });
      expect(seenWord, 'sta');
      expect(seenIsCommand, isFalse);
    });
  });
}
