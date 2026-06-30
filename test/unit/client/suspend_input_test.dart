import 'dart:async';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// Regression test for the `:ide` full-screen takeover seam: while a takeover is
/// active, raw input bytes must be routed to the takeover's stream (not parsed
/// as line editing), and the editor must keep its single stdin subscription —
/// it must not cancel and re-`listen` (stdin is single-subscription).
void main() {
  group('LineEditor.suspendInput', () {
    test('routes raw bytes to the takeover stream, then resumes', () async {
      final input = StreamController<List<int>>();
      final lines = <String>[];
      final editor = LineEditor(
        input: input.stream,
        output: (_) {},
        history: CommandHistory.inMemory(),
        interactive: true,
        setRawMode: (_) {},
        onLine: lines.add,
      )..start();

      final received = <int>[];
      final takeoverDone = Completer<void>();
      final suspend = editor.suspendInput((stream) async {
        final sub = stream.listen(received.addAll);
        await takeoverDone.future;
        await sub.cancel();
      });

      // Bytes sent during the takeover go to the takeover stream, not line edit.
      input.add('hi'.codeUnits);
      await Future<void>.delayed(Duration.zero);
      expect(received, 'hi'.codeUnits);
      expect(lines, isEmpty); // nothing was committed as a line

      // End the takeover; the editor resumes normal line editing.
      takeoverDone.complete();
      await suspend;

      input.add('ls\n'.codeUnits);
      await Future<void>.delayed(Duration.zero);
      expect(lines, ['ls']);

      await input.close();
      await editor.close();
    });

    test(
      'does not throw when stdin is single-subscription (no re-listen)',
      () async {
        // A single-subscription controller models stdin: a second listen would
        // throw. suspendInput must not re-listen, so this completes cleanly.
        final input = StreamController<List<int>>();
        final editor = LineEditor(
          input: input.stream,
          output: (_) {},
          history: CommandHistory.inMemory(),
          interactive: true,
          setRawMode: (_) {},
          onLine: (_) {},
        )..start();

        await editor.suspendInput((stream) async {
          // Touch the stream the way the IDE's Terminal does.
          final sub = stream.listen((_) {});
          await Future<void>.delayed(Duration.zero);
          await sub.cancel();
        });

        await input.close();
        await editor.close();
      },
    );
  });
}
