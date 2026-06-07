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

  _Harness({CommandHistory? history, bool interactive = true}) {
    editor = LineEditor(
      input: controller.stream,
      output: output.write,
      history: history ?? CommandHistory.inMemory(),
      interactive: interactive,
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
  });

  group('LineEditor non-interactive fallback', () {
    test('splits piped input into lines without raw mode', () async {
      final h = _Harness(interactive: false);
      await h.feed(utf8.encode('one\ntwo\n'));
      expect(h.lines, ['one', 'two']);
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
  });
}
