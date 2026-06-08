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
}
