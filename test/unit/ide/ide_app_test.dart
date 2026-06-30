import 'dart:async';
import 'dart:io';

import 'package:omnyshell/src/application/client/ide/ide_app.dart';
import 'package:omnyshell/src/application/client/ide/tui/screen_buffer.dart';
import 'package:omnyshell/src/application/client/ide/tui/terminal.dart';
import 'package:test/test.dart';

/// A scriptable [TerminalDriver] for driving the app without a real TTY.
class FakeTerminal implements TerminalDriver {
  FakeTerminal({this.cols = 100, this.rows = 30});
  final int cols;
  final int rows;
  final _input = StreamController<List<int>>();
  ScreenBuffer? lastFrame;
  bool entered = false;

  void send(List<int> bytes) => _input.add(bytes);

  @override
  ({int cols, int rows}) get size => (cols: cols, rows: rows);
  @override
  void enter() => entered = true;
  @override
  void leave() => entered = false;
  @override
  void invalidate() {}
  @override
  void present(ScreenBuffer frame, {int? cursorX, int? cursorY}) =>
      lastFrame = frame;
  @override
  Stream<List<int>> get input => _input.stream;
  @override
  Stream<void> get resizeEvents => const Stream<void>.empty();
}

/// Flattens a frame into its visible text (rows joined by newlines).
String frameText(ScreenBuffer? f) {
  if (f == null) return '';
  final rows = <String>[];
  for (var y = 0; y < f.height; y++) {
    final sb = StringBuffer();
    for (var x = 0; x < f.width; x++) {
      sb.write(f.cellAt(x, y).char);
    }
    rows.add(sb.toString());
  }
  return rows.join('\n');
}

Future<void> pump([int times = 4]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    // systemTemp is outside any git repo, so GitRepo.discover returns null.
    tmp = Directory.systemTemp.createTempSync('ide_app_test');
    File('${tmp.path}/hello.dart').writeAsStringSync('final x = 1;\n');
    File('${tmp.path}/notes.md').writeAsStringSync('# Title\n');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('renders the file tree on first frame', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    final text = frameText(term.lastFrame);
    expect(text, contains('hello.dart'));
    expect(text, contains('notes.md'));
    term.send([0x11]); // Ctrl-Q quits (nothing unsaved)
    await running;
    expect(term.entered, isFalse); // terminal restored on exit
  });

  test(
    'navigating and opening a file shows its highlighted contents',
    () async {
      final term = FakeTerminal();
      final app = IdeApp(rootPath: tmp.path, terminal: term);
      final running = app.run();
      await pump();

      // Root is selected first; Down moves to hello.dart, Enter opens it.
      term.send([0x1b, 0x5b, 0x42]); // Down
      await pump();
      term.send([0x0d]); // Enter
      await pump();

      final text = frameText(term.lastFrame);
      expect(text, contains('final x = 1;')); // editor shows the source
      expect(text, contains('Dart')); // status bar shows the language

      term.send([0x11]); // Ctrl-Q
      await running;
    },
  );

  test('typing edits the buffer and Ctrl-Q guards unsaved changes', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    term.send([0x1b, 0x5b, 0x42]); // Down -> hello.dart
    await pump();
    term.send([0x0d]); // open (focus moves to editor)
    await pump();
    term.send([0x5a]); // type 'Z'
    await pump();
    expect(frameText(term.lastFrame), contains('Zfinal x = 1;'));

    // First Ctrl-Q is guarded because of the unsaved edit.
    term.send([0x11]);
    await pump();
    expect(frameText(term.lastFrame).toLowerCase(), contains('unsaved'));
    // Second Ctrl-Q discards and quits.
    term.send([0x11]);
    await running;
  });

  test('Ctrl-S saves edits to disk', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    term.send([0x1b, 0x5b, 0x42]); // Down
    await pump();
    term.send([0x0d]); // open
    await pump();
    term.send([0x5a]); // 'Z'
    await pump();
    term.send([0x13]); // Ctrl-S save
    await pump();
    expect(
      File('${tmp.path}/hello.dart').readAsStringSync(),
      'Zfinal x = 1;\n',
    );
    term.send([0x11]); // Ctrl-Q (clean now)
    await running;
  });
}
