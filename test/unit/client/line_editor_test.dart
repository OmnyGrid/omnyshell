import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

// Escape / control sequences as raw bytes.
const _up = [0x1b, 0x5b, 0x41];
const _down = [0x1b, 0x5b, 0x42];
const _left = [0x1b, 0x5b, 0x44];
const _right = [0x1b, 0x5b, 0x43];
const _home = [0x1b, 0x5b, 0x48];
const _end = [0x1b, 0x5b, 0x46];
const _del = [0x1b, 0x5b, 0x33, 0x7e]; // forward delete
const _backspace = [0x7f];
const _ctrlC = [0x03];
const _ctrlD = [0x04];
const _enter = [0x0d];

/// Drives a [LineEditor] with synthetic byte input and records committed lines.
class _Harness {
  final controller = StreamController<List<int>>();
  final lines = <String>[];
  final output = StringBuffer();
  int interrupts = 0;
  int eofs = 0;
  late final LineEditor editor;

  _Harness({CommandHistory? history, bool interactive = true, int width = 0}) {
    editor = LineEditor(
      input: controller.stream,
      output: output.write,
      history: history ?? CommandHistory.inMemory(),
      interactive: interactive,
      width: width,
      setRawMode: (_) {},
      onInterrupt: () => interrupts++,
      onEof: () => eofs++,
      onLine: lines.add,
    );
    editor.start();
  }

  /// Feeds bytes (one or more sequences) and lets the event loop drain.
  Future<void> feed(List<int> bytes) async {
    controller.add(bytes);
    await pumpEventQueue();
  }

  Future<void> type(String s) => feed(utf8.encode(s));

  Future<void> dispose() async {
    await controller.close();
    await editor.close();
  }
}

void main() {
  group('LineEditor editing', () {
    test('commits a typed line on Enter', () async {
      final h = _Harness();
      await h.type('echo hi');
      await h.feed(_enter);
      expect(h.lines, ['echo hi']);
      // The line is echoed back to the terminal.
      expect(h.output.toString(), contains('echo hi'));
      await h.dispose();
    });

    test('backspace deletes the char before the cursor', () async {
      final h = _Harness();
      await h.type('abc');
      await h.feed(_backspace);
      await h.feed(_enter);
      expect(h.lines, ['ab']);
      await h.dispose();
    });

    test('left + insert edits mid-line', () async {
      final h = _Harness();
      await h.type('ac');
      await h.feed(_left);
      await h.type('b');
      await h.feed(_enter);
      expect(h.lines, ['abc']);
      await h.dispose();
    });

    test('right moves the cursor back toward the end', () async {
      final h = _Harness();
      await h.type('ab');
      await h.feed(_left); // cursor between a|b
      await h.feed(_left); // cursor a|b -> |ab
      await h.feed(_right); // a|b
      await h.type('X'); // aXb
      await h.feed(_enter);
      expect(h.lines, ['aXb']);
      await h.dispose();
    });

    test('home and end jump to the line edges', () async {
      final h = _Harness();
      await h.type('bc');
      await h.feed(_home);
      await h.type('a'); // abc
      await h.feed(_end);
      await h.type('d'); // abcd
      await h.feed(_enter);
      expect(h.lines, ['abcd']);
      await h.dispose();
    });

    test('forward delete removes the char under the cursor', () async {
      final h = _Harness();
      await h.type('abc');
      await h.feed(_home);
      await h.feed(_del); // removes 'a'
      await h.feed(_enter);
      expect(h.lines, ['bc']);
      await h.dispose();
    });

    test('multi-byte UTF-8 input is inserted as one character', () async {
      final h = _Harness();
      await h.type('café');
      await h.feed(_backspace); // drops 'é', not a stray byte
      await h.feed(_enter);
      expect(h.lines, ['caf']);
      await h.dispose();
    });

    test('Ctrl-C discards the line and fires onInterrupt', () async {
      final h = _Harness();
      await h.type('abc');
      await h.feed(_ctrlC);
      await h.type('xy');
      await h.feed(_enter);
      expect(h.lines, ['xy']);
      expect(h.interrupts, 1);
      await h.dispose();
    });

    test(
      'Ctrl-D on an empty line fires onEof but not on a filled one',
      () async {
        final h = _Harness();
        await h.type('abc');
        await h.feed(_ctrlD); // ignored: buffer not empty
        expect(h.eofs, 0);
        await h.feed(_backspace);
        await h.feed(_backspace);
        await h.feed(_backspace); // buffer now empty
        await h.feed(_ctrlD);
        expect(h.eofs, 1);
        await h.dispose();
      },
    );
  });

  group('LineEditor history navigation', () {
    test('Up recalls previous commands newest-first', () async {
      final h = _Harness(
        history: CommandHistory.inMemory(entries: ['ls', 'pwd']),
      );
      await h.feed(_up); // -> pwd
      await h.feed(_up); // -> ls
      await h.feed(_enter);
      expect(h.lines, ['ls']);
      await h.dispose();
    });

    test('Down returns to the stashed in-progress line', () async {
      final h = _Harness(
        history: CommandHistory.inMemory(entries: ['ls', 'pwd']),
      );
      await h.type('abc'); // in-progress line
      await h.feed(_up); // stash 'abc' -> 'pwd'
      await h.feed(_down); // -> back to 'abc'
      await h.feed(_enter);
      expect(h.lines, ['abc']);
      await h.dispose();
    });

    test('Up stops at the oldest entry', () async {
      final h = _Harness(history: CommandHistory.inMemory(entries: ['only']));
      await h.feed(_up);
      await h.feed(_up); // no-op past the top
      await h.feed(_enter);
      expect(h.lines, ['only']);
      await h.dispose();
    });

    test('addHistory makes a committed line recallable', () async {
      final h = _Harness();
      await h.type('first');
      await h.feed(_enter);
      await h.editor.addHistory('first');
      await h.feed(_up);
      await h.feed(_enter);
      expect(h.lines, ['first', 'first']);
      await h.dispose();
    });

    test('Up filters history by the typed prefix, newest-first', () async {
      final h = _Harness(
        history: CommandHistory.inMemory(
          entries: ['git status', 'ls -la', 'git commit'],
        ),
      );
      await h.type('git ');
      await h.feed(_up); // -> 'git commit' (skips 'ls -la')
      await h.feed(_up); // -> 'git status'
      await h.feed(_enter);
      expect(h.lines, ['git status']);
      await h.dispose();
    });

    test(
      'Down walks forward within matches, then restores the prefix',
      () async {
        final h = _Harness(
          history: CommandHistory.inMemory(
            entries: ['git status', 'ls', 'git commit'],
          ),
        );
        await h.type('git ');
        await h.feed(_up); // 'git commit'
        await h.feed(_up); // 'git status'
        await h.feed(_down); // 'git commit'
        await h.feed(_down); // back to the in-progress 'git '
        await h.feed(_enter);
        expect(h.lines, ['git ']);
        await h.dispose();
      },
    );

    test('a non-matching prefix recalls nothing', () async {
      final h = _Harness(
        history: CommandHistory.inMemory(entries: ['ls', 'pwd']),
      );
      await h.type('zzz');
      await h.feed(_up); // no entry starts with 'zzz'
      await h.feed(_enter);
      expect(h.lines, ['zzz']);
      await h.dispose();
    });

    test('editing the line recomputes the prefix for the next Up', () async {
      final h = _Harness(
        history: CommandHistory.inMemory(entries: ['foo', 'bar']),
      );
      await h.type('x');
      await h.feed(_up); // 'x' matches nothing -> stays 'x'
      await h.feed(_backspace); // line now empty, prefix reset
      await h.feed(_up); // empty prefix -> newest entry 'bar'
      await h.feed(_enter);
      expect(h.lines, ['bar']);
      await h.dispose();
    });
  });

  group('LineEditor non-interactive fallback', () {
    test('splits piped input into lines without raw mode', () async {
      final h = _Harness(interactive: false);
      await h.feed(utf8.encode('one\ntwo\n'));
      expect(h.lines, ['one', 'two']);
      await h.dispose();
    });
  });

  group('LineEditor prompt', () {
    // Builds an editor whose command handler asks a question via prompt(), so we
    // can verify a confirmation can be answered while the command is running.
    ({StreamController<List<int>> input, List<String?> answers}) build() {
      final input = StreamController<List<int>>();
      final answers = <String?>[];
      late final LineEditor editor;
      editor = LineEditor(
        input: input.stream,
        output: (_) {},
        history: CommandHistory.inMemory(),
        interactive: true,
        setRawMode: (_) {},
        onLine: (line) async {
          answers.add(await editor.prompt('Proceed? [y/N] '));
        },
      );
      editor.start();
      return (input: input, answers: answers);
    }

    test('a running command can read its answer line', () async {
      final h = build();
      h.input.add(utf8.encode('run\r')); // commits -> onLine -> awaits prompt
      await pumpEventQueue();
      h.input.add(utf8.encode('y\r')); // answers the prompt
      await pumpEventQueue();
      expect(h.answers, ['y']);
      await h.input.close();
    });

    test('the answer line is not also run as a command', () async {
      final lines = <String>[];
      final input = StreamController<List<int>>();
      late final LineEditor editor;
      var asked = false;
      editor = LineEditor(
        input: input.stream,
        output: (_) {},
        history: CommandHistory.inMemory(),
        interactive: true,
        setRawMode: (_) {},
        onLine: (line) async {
          lines.add(line);
          if (!asked) {
            asked = true;
            await editor.prompt('? ');
          }
        },
      );
      editor.start();
      input.add(utf8.encode('cmd\r'));
      await pumpEventQueue();
      input.add(utf8.encode('y\r'));
      await pumpEventQueue();
      // Only the real command reached onLine; 'y' answered the prompt.
      expect(lines, ['cmd']);
      await input.close();
    });

    test('Ctrl-C cancels a pending prompt with an empty answer', () async {
      final h = build();
      h.input.add(utf8.encode('run\r'));
      await pumpEventQueue();
      h.input.add([0x03]); // Ctrl-C
      await pumpEventQueue();
      expect(h.answers, ['']);
      await h.input.close();
    });
  });

  group('LineEditor passthrough', () {
    test('entering passthrough erases a dangling prompt line', () async {
      final h = _Harness();
      h.editor.setPrompt('P> ');
      // The AI agent prints a "\$ cmd" header via printAbove, whose repaint
      // leaves a prompt on the current line.
      h.editor.printAbove(() => h.output.write('\$ cat file\n'));
      h.output.clear();

      h.editor.setPassthrough(true);

      // The dangling prompt is erased so the command's raw output starts clean.
      expect(h.output.toString(), '\r\x1b[K');
      await h.dispose();
    });

    test('leaving passthrough does not erase', () async {
      final h = _Harness();
      h.editor.setPassthrough(true);
      h.output.clear();
      h.editor.setPassthrough(false);
      expect(h.output.toString(), isEmpty);
      await h.dispose();
    });

    test('redundant setPassthrough(true) erases only once', () async {
      final h = _Harness();
      h.editor.setPassthrough(true);
      h.output.clear();
      h.editor.setPassthrough(true); // no transition
      expect(h.output.toString(), isEmpty);
      await h.dispose();
    });
  });

  group('LineEditor idle prompt hiding', () {
    test('hidden idle prompt is not drawn by printAbove', () async {
      final h = _Harness();
      h.editor.setPrompt('P> ');
      h.editor.hideIdlePrompt(true);
      h.output.clear();
      h.editor.printAbove(() => h.output.write('line\n'));
      // The content is written but no prompt is repainted afterwards.
      expect(h.output.toString(), '\r\x1b[Kline\n\r\x1b[K');
      expect(h.output.toString(), isNot(contains('P> ')));
      await h.dispose();
    });

    test(
      'a pending prompt question still shows while idle prompt is hidden',
      () async {
        final h = _Harness();
        h.editor.hideIdlePrompt(true);
        h.output.clear();
        final answer = h.editor.prompt('Run? ');
        expect(h.output.toString(), contains('Run? ')); // question is visible
        await h.feed(utf8.encode('y\r'));
        expect(await answer, 'y');
        await h.dispose();
      },
    );

    test('restoring the idle prompt repaints it', () async {
      final h = _Harness();
      h.editor.setPrompt('P> ');
      h.editor.hideIdlePrompt(true);
      h.output.clear();
      h.editor.hideIdlePrompt(false);
      expect(h.output.toString(), contains('P> '));
      await h.dispose();
    });
  });

  group('CommandHistory persistence', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('omnyshell_hist');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('persists and reloads entries for a key', () async {
      final h = await CommandHistory.load(key: 'alice@node1', home: tmp.path);
      await h.add('ls');
      await h.add('pwd');
      final reloaded = await CommandHistory.load(
        key: 'alice@node1',
        home: tmp.path,
      );
      expect(reloaded.entries, ['ls', 'pwd']);
    });

    test('keeps separate files per key', () async {
      final a = await CommandHistory.load(key: 'alice@node1', home: tmp.path);
      final b = await CommandHistory.load(key: 'bob@node2', home: tmp.path);
      await a.add('alice-cmd');
      await b.add('bob-cmd');
      final reA = await CommandHistory.load(key: 'alice@node1', home: tmp.path);
      final reB = await CommandHistory.load(key: 'bob@node2', home: tmp.path);
      expect(reA.entries, ['alice-cmd']);
      expect(reB.entries, ['bob-cmd']);
    });

    test('skips blanks and consecutive duplicates', () async {
      final h = await CommandHistory.load(key: 'k', home: tmp.path);
      await h.add('ls');
      await h.add('ls'); // dup
      await h.add('   '); // blank
      await h.add('pwd');
      expect(h.entries, ['ls', 'pwd']);
    });

    test('trims to the max-entry cap', () async {
      final h = await CommandHistory.load(
        key: 'k',
        home: tmp.path,
        maxEntries: 3,
      );
      for (final c in ['a', 'b', 'c', 'd', 'e']) {
        await h.add(c);
      }
      expect(h.entries, ['c', 'd', 'e']);
      final reloaded = await CommandHistory.load(
        key: 'k',
        home: tmp.path,
        maxEntries: 3,
      );
      expect(reloaded.entries, ['c', 'd', 'e']);
    });

    test('round-trips under a UID-shaped key', () async {
      // A node UID: `nod_` prefix plus url-safe base64 (`-`/`_`).
      const key = 'alice@nod_Ab-cD_eF12';
      final h = await CommandHistory.load(key: key, home: tmp.path);
      await h.add('ls');
      await h.add('pwd');
      final reloaded = await CommandHistory.load(key: key, home: tmp.path);
      expect(reloaded.entries, ['ls', 'pwd']);
    });
  });

  group('CommandHistory.migrate', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('omnyshell_hist');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('copies entries to the new key and keeps the source', () async {
      final old = await CommandHistory.load(key: 'u@old', home: tmp.path);
      await old.add('ls');
      await old.add('pwd');

      await CommandHistory.migrate(
        fromKey: 'u@old',
        toKey: 'u@new',
        home: tmp.path,
      );

      final migrated = await CommandHistory.load(key: 'u@new', home: tmp.path);
      expect(migrated.entries, ['ls', 'pwd']);
      // Source is left intact as a backup.
      final source = await CommandHistory.load(key: 'u@old', home: tmp.path);
      expect(source.entries, ['ls', 'pwd']);
    });

    test(
      'places migrated entries before existing destination entries',
      () async {
        final old = await CommandHistory.load(key: 'u@old', home: tmp.path);
        await old.add('old1');
        await old.add('old2');
        final dest = await CommandHistory.load(key: 'u@new', home: tmp.path);
        await dest.add('new1');

        await CommandHistory.migrate(
          fromKey: 'u@old',
          toKey: 'u@new',
          home: tmp.path,
        );

        final merged = await CommandHistory.load(key: 'u@new', home: tmp.path);
        expect(merged.entries, ['old1', 'old2', 'new1']);
      },
    );

    test('collapses a duplicate at the splice boundary', () async {
      final old = await CommandHistory.load(key: 'u@old', home: tmp.path);
      await old.add('a');
      await old.add('dup');
      final dest = await CommandHistory.load(key: 'u@new', home: tmp.path);
      await dest.add('dup');
      await dest.add('b');

      await CommandHistory.migrate(
        fromKey: 'u@old',
        toKey: 'u@new',
        home: tmp.path,
      );

      final merged = await CommandHistory.load(key: 'u@new', home: tmp.path);
      expect(merged.entries, ['a', 'dup', 'b']);
    });

    test('is a no-op when the source is missing', () async {
      final dest = await CommandHistory.load(key: 'u@new', home: tmp.path);
      await dest.add('keep');

      await CommandHistory.migrate(
        fromKey: 'u@absent',
        toKey: 'u@new',
        home: tmp.path,
      );

      final after = await CommandHistory.load(key: 'u@new', home: tmp.path);
      expect(after.entries, ['keep']);
    });
  });

  group('LineEditor multi-row repaint (known width)', () {
    // A cursor-up (`ESC [ <n> A`) only appears when the editor clears a wrapped
    // row — the single-row path never emits it. Its presence is the signal that
    // a repaint spanned more than one row instead of staircasing.
    final cursorUp = RegExp(r'\x1b\[\d*A');

    test(
      'repaints across wrapped rows instead of per-keystroke prompts',
      () async {
        // Width 10, no prompt: the 11th char wraps onto a second row.
        final h = _Harness(width: 10);
        await h.type('abcdefghij'); // exactly fills row 0
        h.output.clear();
        await h.type('kl'); // wraps to row 1
        // The wrapped repaint moved the cursor up to clear the first row.
        expect(h.output.toString(), matches(cursorUp));
        await h.feed(_enter);
        expect(h.lines, ['abcdefghijkl']);
        await h.dispose();
      },
    );

    test('history recall + typing keeps a single logical line', () async {
      final history = CommandHistory.inMemory();
      await history.add('this-is-a-long-recalled-command');
      final h = _Harness(width: 12, history: history);
      await h.feed(_up); // recall the long (wrapping) command
      await h.type('X'); // append a char to the wrapped line
      await h.feed(_enter);
      expect(h.lines, ['this-is-a-long-recalled-commandX']);
      await h.dispose();
    });

    test('edits mid-wrapped-line via Home reposition correctly', () async {
      final h = _Harness(width: 5);
      await h.type('abcdefg'); // wraps: 'abcde' | 'fg'
      await h.feed(_home);
      await h.type('X'); // insert at start -> 'Xabcdefg'
      await h.feed(_enter);
      expect(h.lines, ['Xabcdefg']);
      await h.dispose();
    });

    test('setWidth switches on the multi-row path', () async {
      final h = _Harness(); // width 0 -> single-row fallback
      await h.type('abcdefghij');
      h.output.clear();
      await h.type('k');
      // Unknown width: no cursor-up clears, just single-row erases.
      expect(h.output.toString(), isNot(matches(cursorUp)));

      h.editor.setWidth(10);
      h.output.clear();
      await h.type('lmno'); // now well past one row
      expect(h.output.toString(), matches(cursorUp));
      await h.feed(_enter);
      expect(h.lines, ['abcdefghijklmno']);
      await h.dispose();
    });
  });
}
