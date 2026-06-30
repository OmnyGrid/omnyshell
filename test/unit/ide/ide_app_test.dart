import 'dart:async';
import 'dart:io';

import 'package:omnyshell/src/application/ai/providers/ai_provider.dart';
import 'package:omnyshell/src/version.dart';
import 'package:omnyshell/src/application/client/ide/agent/agent_backend.dart';
import 'package:omnyshell/src/application/client/ide/ide_app.dart';
import 'package:omnyshell/src/application/client/ide/terminal/command_runner.dart';
import 'package:omnyshell/src/application/client/ide/tui/screen_buffer.dart';
import 'package:omnyshell/src/application/client/ide/tui/terminal.dart';
import 'package:test/test.dart';

/// A chat-only [AgentBackend] returning a canned reply (no tools).
class FakeAgentBackend implements AgentBackend {
  FakeAgentBackend([this.reply = 'Hello from the AI.']);
  final String reply;
  final List<String> prompts = [];

  @override
  bool get available => true;
  @override
  String get unavailableReason => '';
  @override
  Future<String> send({
    required String prompt,
    required AgentContext context,
    required List<AgentTurn> history,
  }) async {
    prompts.add(prompt);
    return reply;
  }

  @override
  void close() {}
}

/// An [AiProvider] that replays a scripted list of [AiResult]s, one per call.
class FakeAiProvider implements AiProvider {
  FakeAiProvider(this.results);
  final List<AiResult> results;
  int _i = 0;

  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) async {
    final r = _i < results.length ? results[_i] : const AiResult(text: '');
    _i++;
    return r;
  }

  @override
  void close() {}
}

/// A [CommandRunner] that replays canned output for each command instead of
/// spawning real processes.
class FakeCommandRunner implements CommandRunner {
  FakeCommandRunner([this.outputs = const {}]);
  final Map<String, List<String>> outputs;
  final List<({String command, String cwd})> calls = [];

  @override
  CommandExecution run(String command, String cwd) {
    calls.add((command: command, cwd: cwd));
    final controller = StreamController<String>();
    final lines = outputs[command] ?? ['(no output for "$command")'];
    scheduleMicrotask(() async {
      for (final line in lines) {
        controller.add(line);
      }
      await controller.close();
    });
    return CommandExecution(
      output: controller.stream,
      exitCode: Future.value(0),
      kill: () {},
    );
  }
}

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
    File(
      '${tmp.path}/multi.dart',
    ).writeAsStringSync('alpha\nbeta\ngamma needle\ndelta\nepsilon\n');
    File('${tmp.path}/notes.md').writeAsStringSync('# Title\n');
  });

  /// Opens multi.dart (the 5-line fixture) and leaves focus in the editor.
  Future<void> openMulti(FakeTerminal term) async {
    term.send([0x1b, 0x5b, 0x42]); // Down -> hello.dart
    await pump();
    term.send([0x1b, 0x5b, 0x42]); // Down -> multi.dart
    await pump();
    term.send([0x0d]); // open
    await pump();
  }

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

  test('the welcome screen shows the version and shortcuts', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    final text = frameText(term.lastFrame);
    expect(text, contains('OmnyShell IDE'));
    expect(text, contains('v$omnyShellVersion')); // version shown
    expect(text, contains('new file')); // tree shortcut
    expect(text, contains('AI agent')); // panel shortcut
    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('shows the persistent key-hint bar with the shortcuts', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    // Tree is focused first, so the tree-only keys lead the bar.
    var text = frameText(term.lastFrame);
    expect(text, contains('n new file'));
    expect(text, contains('N new folder'));
    expect(text, contains('. hidden'));
    expect(text, contains('^Q quit'));

    // With the editor focused, the global shortcuts (incl. ^W close) show.
    term.send([0x1b, 0x5b, 0x42]); // Down -> hello.dart
    await pump();
    term.send([0x0d]); // open -> editor focus
    await pump();
    text = frameText(term.lastFrame);
    expect(text, isNot(contains('n new file'))); // tree keys gone
    expect(text, contains('^W close'));
    expect(text, contains('^Q quit'));

    term.send([0x11]); // Ctrl-Q quits
    await running;
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

  test('Ctrl-W on a modified tab confirms, then discards and closes', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    term.send([0x1b, 0x5b, 0x42]); // Down -> hello.dart
    await pump();
    term.send([0x0d]); // open (focus -> editor)
    await pump();
    term.send([0x5a]); // type 'Z' -> dirty
    await pump();
    expect(frameText(term.lastFrame), contains('Zfinal x = 1;'));

    // First Ctrl-W is guarded and asks to confirm.
    term.send([0x17]);
    await pump();
    expect(
      frameText(term.lastFrame).toLowerCase(),
      contains('discard and close'),
    );
    // Tab is still open and unchanged on disk.
    expect(frameText(term.lastFrame), contains('Zfinal x = 1;'));
    expect(File('${tmp.path}/hello.dart').readAsStringSync(), 'final x = 1;\n');

    // Second Ctrl-W discards and closes the tab (back to the welcome screen).
    term.send([0x17]);
    await pump();
    final text = frameText(term.lastFrame);
    expect(text, isNot(contains('Zfinal x = 1;')));
    expect(text, contains('OmnyShell IDE')); // welcome screen
    // Discarded, not saved.
    expect(File('${tmp.path}/hello.dart').readAsStringSync(), 'final x = 1;\n');

    term.send([0x11]); // Ctrl-Q (nothing unsaved now)
    await running;
  });

  test('Ctrl-W confirm is cancelled by an unrelated key', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    term.send([0x1b, 0x5b, 0x42]); // Down -> hello.dart
    await pump();
    term.send([0x0d]); // open
    await pump();
    term.send([0x5a]); // 'Z' -> dirty
    await pump();
    term.send([0x17]); // Ctrl-W -> armed
    await pump();
    expect(
      frameText(term.lastFrame).toLowerCase(),
      contains('discard and close'),
    );

    // Any other edit cancels the confirmation; the tab stays open.
    term.send([0x59]); // type 'Y'
    await pump();
    expect(frameText(term.lastFrame), contains('ZYfinal x = 1;'));

    // A fresh Ctrl-W re-arms rather than closing immediately.
    term.send([0x17]);
    await pump();
    expect(
      frameText(term.lastFrame).toLowerCase(),
      contains('discard and close'),
    );
    expect(frameText(term.lastFrame), contains('ZYfinal x = 1;'));

    term.send([0x17]); // confirm discard+close
    await pump();
    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('Ctrl-L opens a dialog and jumps to the given line', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    await openMulti(term);
    expect(frameText(term.lastFrame), contains('Ln 1, Col 1'));

    term.send([0x0c]); // Ctrl-L
    await pump();
    expect(frameText(term.lastFrame), contains('Go to line')); // dialog shown

    term.send([0x33]); // '3'
    await pump();
    term.send([0x0d]); // Enter
    await pump();
    final text = frameText(term.lastFrame);
    expect(text, isNot(contains('Go to line'))); // dialog dismissed
    expect(text, contains('Ln 3, Col 1')); // caret moved to line 3

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('Ctrl-L ignores non-digits and Esc cancels', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    await openMulti(term);

    term.send([0x0c]); // Ctrl-L
    await pump();
    term.send([0x78]); // 'x' -> ignored (digits only)
    await pump();
    term.send([0x32]); // '2'
    await pump();
    // Esc cancels. The decoder buffers a lone ESC until the next byte arrives
    // (it can't tell a bare Esc from an escape sequence), so a second ESC byte
    // flushes the first as an Escape key.
    term.send([0x1b]);
    await pump();
    term.send([0x1b]);
    await pump();
    final text = frameText(term.lastFrame);
    expect(text, isNot(contains('Go to line')));
    expect(text, contains('Ln 1, Col 1')); // unchanged

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('Ctrl-F finds text and moves the caret to the match', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    await openMulti(term);

    term.send([0x06]); // Ctrl-F
    await pump();
    expect(frameText(term.lastFrame), contains('Find')); // dialog shown

    for (final c in 'needle'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]); // Enter
    await pump();
    expect(frameText(term.lastFrame), contains('Found "needle" at line 3'));

    // The caret really moved: clear the message and read the status position.
    term.send([0x1b, 0x5b, 0x43]); // Right arrow
    await pump();
    expect(frameText(term.lastFrame), contains('Ln 3'));

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('Ctrl-F reports when text is not found', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    await openMulti(term);

    term.send([0x06]); // Ctrl-F
    await pump();
    for (final c in 'zzz'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]); // Enter
    await pump();
    expect(frameText(term.lastFrame), contains('"zzz" not found'));

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('Ctrl-T toggles the integrated terminal panel', () async {
    final term = FakeTerminal();
    final app = IdeApp(
      rootPath: tmp.path,
      terminal: term,
      commandRunner: FakeCommandRunner(),
    );
    final running = app.run();
    await pump();
    expect(frameText(term.lastFrame), isNot(contains('TERMINAL')));

    term.send([0x14]); // Ctrl-T -> open + focus
    await pump();
    expect(frameText(term.lastFrame), contains('TERMINAL'));

    term.send([0x14]); // Ctrl-T again -> hide
    await pump();
    expect(frameText(term.lastFrame), isNot(contains('TERMINAL')));

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('terminal runs a command and shows its output', () async {
    final term = FakeTerminal();
    final runner = FakeCommandRunner({
      'git status': ['On branch feat/tui-ide-mode', 'nothing to commit'],
    });
    final app = IdeApp(
      rootPath: tmp.path,
      terminal: term,
      commandRunner: runner,
    );
    final running = app.run();
    await pump();
    term.send([0x14]); // Ctrl-T
    await pump();

    for (final c in 'git status'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]); // Enter -> run
    await pump();

    final text = frameText(term.lastFrame);
    expect(text, contains(r'$ git status')); // echoed command
    expect(text, contains('On branch feat/tui-ide-mode')); // streamed output
    expect(text, contains('nothing to commit'));
    expect(runner.calls.single.command, 'git status');
    expect(runner.calls.single.cwd, tmp.path); // ran in the IDE root

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test(
    'terminal cd changes the working directory for later commands',
    () async {
      Directory('${tmp.path}/sub').createSync();
      final term = FakeTerminal();
      final runner = FakeCommandRunner({
        'pwd': ['ignored'],
      });
      final app = IdeApp(
        rootPath: tmp.path,
        terminal: term,
        commandRunner: runner,
      );
      final running = app.run();
      await pump();
      term.send([0x14]); // Ctrl-T
      await pump();

      for (final c in 'cd sub'.codeUnits) {
        term.send([c]);
      }
      await pump();
      term.send([0x0d]); // Enter -> intercepted, no process spawned
      await pump();
      expect(runner.calls, isEmpty); // cd handled internally

      for (final c in 'pwd'.codeUnits) {
        term.send([c]);
      }
      await pump();
      term.send([0x0d]);
      await pump();
      expect(runner.calls.single.cwd, '${tmp.path}/sub'); // ran in the new cwd

      term.send([0x11]); // Ctrl-Q
      await running;
    },
  );

  test('Esc returns focus from the terminal to the editor', () async {
    final term = FakeTerminal();
    final app = IdeApp(
      rootPath: tmp.path,
      terminal: term,
      commandRunner: FakeCommandRunner(),
    );
    final running = app.run();
    await pump();
    term.send([0x1b, 0x5b, 0x42]); // Down -> hello.dart
    await pump();
    term.send([0x0d]); // open a file (so editor focus is meaningful)
    await pump();
    term.send([0x14]); // Ctrl-T -> terminal focus
    await pump();

    // Typing goes to the terminal input, not the editor.
    term.send([0x78]); // 'x'
    await pump();
    expect(frameText(term.lastFrame), contains(r'$ x'));

    // Esc hands focus back to the editor; the panel stays visible. Send a second
    // byte to flush the decoder's buffered lone ESC.
    term.send([0x1b]);
    await pump();
    term.send([0x59]); // 'Y' -> now edits the file
    await pump();
    final text = frameText(term.lastFrame);
    expect(text, contains('TERMINAL')); // panel still open
    expect(text, contains('Yfinal x = 1;')); // edit landed in the editor

    term.send([0x11]); // Ctrl-Q
    await pump();
    term.send([0x11]); // discard unsaved + quit
    await running;
  });

  test('Ctrl-A opens the AI panel with context and shows a reply', () async {
    final term = FakeTerminal();
    final backend = FakeAgentBackend('Use a for-loop.');
    final app = IdeApp(
      rootPath: tmp.path,
      terminal: term,
      agentBackend: backend,
    );
    final running = app.run();
    await pump();
    term.send([0x1b, 0x5b, 0x42]); // Down -> hello.dart
    await pump();
    term.send([0x0d]); // open it (context becomes the file)
    await pump();

    term.send([0x01]); // Ctrl-A
    await pump();
    expect(frameText(term.lastFrame), contains('AI AGENT'));
    expect(frameText(term.lastFrame), contains('hello.dart')); // context label

    for (final c in 'how?'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]); // send the prompt
    await pump(20);
    final text = frameText(term.lastFrame);
    expect(text, contains('› how?')); // echoed prompt
    expect(text, contains('Use a for-loop.')); // reply
    expect(backend.prompts.single, 'how?');

    term.send([0x14]); // Ctrl-T would... no: just quit
    await pump();
    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('the AI agent edits a file via the write_file tool', () async {
    final term = FakeTerminal();
    final provider = FakeAiProvider([
      AiResult(
        toolCalls: [
          AiToolCall(
            id: '1',
            name: 'write_file',
            arguments: {'path': 'README.md', 'content': '# Hello\n'},
          ),
        ],
        stopReason: AiStopReason.toolUse,
      ),
      const AiResult(text: 'Created README.md.'),
    ]);
    final app = IdeApp(
      rootPath: tmp.path,
      terminal: term,
      aiProvider: provider,
    );
    final running = app.run();
    await pump();
    term.send([0x01]); // Ctrl-A
    await pump();
    for (final c in 'make a readme'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]);
    await pump(40);

    expect(File('${tmp.path}/README.md').readAsStringSync(), '# Hello\n');
    final text = frameText(term.lastFrame);
    expect(text, contains('wrote README.md'));
    expect(text, contains('Created README.md.'));

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('the AI agent runs a safe command without confirmation', () async {
    final term = FakeTerminal();
    final runner = FakeCommandRunner({
      'echo hi': ['hi'],
    });
    final provider = FakeAiProvider([
      AiResult(
        toolCalls: [
          AiToolCall(
            id: '1',
            name: 'run_command',
            arguments: {'command': 'echo hi'},
          ),
        ],
        stopReason: AiStopReason.toolUse,
      ),
      const AiResult(text: 'Printed hi.'),
    ]);
    final app = IdeApp(
      rootPath: tmp.path,
      terminal: term,
      aiProvider: provider,
      commandRunner: runner,
    );
    final running = app.run();
    await pump();
    term.send([0x01]); // Ctrl-A
    await pump();
    for (final c in 'run it'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]);
    await pump(40);

    final text = frameText(term.lastFrame);
    expect(text, contains(r'$ echo hi'));
    expect(text, contains('hi'));
    expect(text, contains('Printed hi.'));
    expect(runner.calls.single.command, 'echo hi');
    expect(runner.calls.single.cwd, tmp.path);

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('the AI agent confirms a risky command before running', () async {
    final term = FakeTerminal();
    final runner = FakeCommandRunner({
      'rm notes.txt': ['removed'],
    });
    final provider = FakeAiProvider([
      AiResult(
        toolCalls: [
          AiToolCall(
            id: '1',
            name: 'run_command',
            arguments: {'command': 'rm notes.txt'},
          ),
        ],
        stopReason: AiStopReason.toolUse,
      ),
      const AiResult(text: 'Removed it.'),
    ]);
    final app = IdeApp(
      rootPath: tmp.path,
      terminal: term,
      aiProvider: provider,
      commandRunner: runner,
    );
    final running = app.run();
    await pump();
    term.send([0x01]); // Ctrl-A
    await pump();
    for (final c in 'remove notes'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]);
    await pump(20);

    // A confirmation dialog appears (rm is review/mediumRisk) and nothing ran.
    expect(frameText(term.lastFrame), contains('Run command?'));
    expect(frameText(term.lastFrame), contains('rm notes.txt'));
    expect(runner.calls, isEmpty);

    term.send([0x79]); // 'y' -> approve
    await pump(40);
    final text = frameText(term.lastFrame);
    expect(text, contains('removed'));
    expect(text, contains('Removed it.'));
    expect(runner.calls.single.command, 'rm notes.txt');

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('the AI agent blocks a dangerous command via command_shield', () async {
    final term = FakeTerminal();
    final runner = FakeCommandRunner();
    final provider = FakeAiProvider([
      AiResult(
        toolCalls: [
          AiToolCall(
            id: '1',
            name: 'run_command',
            arguments: {'command': 'rm -rf /'},
          ),
        ],
        stopReason: AiStopReason.toolUse,
      ),
      const AiResult(text: 'I will not do that.'),
    ]);
    final app = IdeApp(
      rootPath: tmp.path,
      terminal: term,
      aiProvider: provider,
      commandRunner: runner,
    );
    final running = app.run();
    await pump();
    term.send([0x01]); // Ctrl-A
    await pump();
    for (final c in 'wipe disk'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]);
    await pump(40);

    final text = frameText(term.lastFrame);
    expect(text, contains('BLOCKED')); // shield blocked it
    expect(runner.calls, isEmpty); // never executed

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('tree: "n" creates a new file and opens it', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    // Tree is focused with the root selected; "n" opens the new-file prompt.
    term.send([0x6e]); // 'n'
    await pump();
    expect(frameText(term.lastFrame), contains('New file'));

    for (final c in 'foo.txt'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]); // create
    await pump();

    expect(File('${tmp.path}/foo.txt').existsSync(), isTrue);
    expect(frameText(term.lastFrame), contains('foo.txt')); // in tree + tab

    term.send([0x11]); // Ctrl-Q (new empty file is not dirty)
    await running;
  });

  test('tree: "N" creates a new folder', () async {
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    term.send([0x4e]); // 'N'
    await pump();
    expect(frameText(term.lastFrame), contains('New folder'));

    for (final c in 'widgets'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]); // create
    await pump();

    expect(Directory('${tmp.path}/widgets').existsSync(), isTrue);
    expect(frameText(term.lastFrame), contains('widgets')); // appears in tree

    term.send([0x11]); // Ctrl-Q
    await running;
  });

  test('tree: a new file is created inside the selected directory', () async {
    Directory('${tmp.path}/lib').createSync();
    final term = FakeTerminal();
    final app = IdeApp(rootPath: tmp.path, terminal: term);
    final running = app.run();
    await pump();
    // Select the "lib" directory (Down from the root; lib sorts before files).
    term.send([0x1b, 0x5b, 0x42]); // Down -> lib/
    await pump();
    term.send([0x6e]); // 'n'
    await pump();
    for (final c in 'main.dart'.codeUnits) {
      term.send([c]);
    }
    await pump();
    term.send([0x0d]);
    await pump();

    expect(File('${tmp.path}/lib/main.dart').existsSync(), isTrue);

    term.send([0x11]); // Ctrl-Q
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
