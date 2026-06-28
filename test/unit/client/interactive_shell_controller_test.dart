@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// An in-memory [ShellSessionPort] for driving [InteractiveShellController]
/// without a real session.
class FakeShellSessionPort implements ShellSessionPort {
  final StreamController<Uint8List> _stdout = StreamController<Uint8List>();
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>();
  final Completer<int> _exit = Completer<int>();

  @override
  ShellFamily shellFamily;

  @override
  SessionId? id;

  bool _wasDetached = false;

  final List<List<int>> stdin = [];
  final List<(int, int)> resizes = [];
  final List<int> grants = [];
  int interrupts = 0;
  bool detached = false;
  bool closed = false;

  FakeShellSessionPort({this.shellFamily = ShellFamily.posix, this.id});

  void emitStdout(List<int> bytes) {
    if (!_stdout.isClosed) _stdout.add(Uint8List.fromList(bytes));
  }

  void emitStderr(List<int> bytes) {
    if (!_stderr.isClosed) _stderr.add(Uint8List.fromList(bytes));
  }

  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool get wasDetached => _wasDetached;

  @override
  void writeStdin(List<int> data) => stdin.add(data);

  @override
  void resize({required int cols, required int rows}) =>
      resizes.add((cols, rows));

  @override
  void grantWindow(int credit) => grants.add(credit);

  @override
  void interrupt() => interrupts++;

  @override
  Future<void> detach() async {
    detached = true;
    _wasDetached = true;
    await _close();
  }

  @override
  Future<void> close() async {
    closed = true;
    await _close();
  }

  Future<void> _close() async {
    if (!_stdout.isClosed) await _stdout.close();
    if (!_stderr.isClosed) await _stderr.close();
  }
}

void main() {
  late FakeShellSessionPort port;
  late CwdMarker marker;
  late List<int> output;
  late List<ShellPromptState> prompts;
  late List<bool> passthrough;
  int? exitCode;

  InteractiveShellController build({bool resumedInAltScreen = false}) {
    output = [];
    prompts = [];
    passthrough = [];
    exitCode = null;
    return InteractiveShellController(
      session: port,
      marker: marker,
      resumedInAltScreen: resumedInAltScreen,
      onOutput: output.addAll,
      onPrompt: prompts.add,
      onPassthrough: passthrough.add,
      onExit: (c) => exitCode = c,
    )..start();
  }

  setUp(() {
    port = FakeShellSessionPort();
    marker = CwdMarker('testnonce');
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  String sent() =>
      port.stdin.map((b) => utf8.decode(b, allowMalformed: true)).join();
  String markerLine(String cwd) => '${marker.token}$cwd\t\t\t\n';

  test('start primes the shell with an init line and a marker', () {
    build();
    final s = sent();
    expect(s, contains("trap ':' INT")); // POSIX init line
    expect(s, contains('printf')); // marker command
    expect(s, isNot(contains(marker.token))); // token split across printf args
  });

  test('a completing marker reports the prompt state (cwd)', () async {
    build();
    port.emitStdout(utf8.encode(markerLine('/home/alice')));
    await pump();
    expect(prompts, hasLength(1));
    expect(prompts.single.cwd, '/home/alice');
    expect(passthrough.last, isFalse);
  });

  test(
    'submitLine wraps the command, enters passthrough, and dispatches',
    () async {
      final c = build();
      port.emitStdout(utf8.encode(markerLine('/home/alice')));
      await pump();
      port.stdin.clear();

      c.submitLine('ls');
      expect(passthrough.last, isTrue);
      final cmd = sent();
      expect(cmd, contains("eval 'ls'"));
      expect(cmd, contains('printf')); // trailing marker
    },
  );

  test('a blank line just repaints the prompt (no command sent)', () async {
    final c = build();
    port.emitStdout(utf8.encode(markerLine('/home/alice')));
    await pump();
    port.stdin.clear();
    c.submitLine('   ');
    expect(port.stdin, isEmpty);
    expect(prompts.length, 2);
  });

  test('output has the marker line stripped', () async {
    build();
    port.emitStdout(utf8.encode('hello world\n${markerLine('/home/alice')}'));
    await pump();
    final shown = utf8.decode(output, allowMalformed: true);
    expect(shown, contains('hello world'));
    expect(shown, isNot(contains(marker.token)));
  });

  test('stdout grants the send window for consumed bytes', () async {
    build();
    port.grants.clear();
    port.emitStdout(utf8.encode('abcd'));
    await pump();
    expect(port.grants, contains(4));
  });

  test('stderr is forwarded as output and grants window', () async {
    build();
    port.emitStderr(utf8.encode('oops'));
    await pump();
    expect(utf8.decode(output, allowMalformed: true), contains('oops'));
    expect(port.grants, contains(4));
  });

  test('sendRaw relays bytes; interrupt and resize forward to the port', () {
    final c = build();
    port.stdin.clear();
    c.sendRaw(const [1, 2, 3]);
    expect(port.stdin.single, [1, 2, 3]);
    c.interrupt();
    expect(port.interrupts, 1);
    c.resize(120, 40);
    expect(port.resizes, contains((120, 40)));
  });

  test('exit reports the code and marks ended', () async {
    final c = build();
    port.exit(7);
    await pump();
    expect(exitCode, 7);
    expect(c.ended, isTrue);
  });

  test('resumedInAltScreen starts in passthrough without priming', () {
    build(resumedInAltScreen: true);
    expect(passthrough, [true]);
    expect(sent(), isEmpty); // no init line / marker sent
  });

  test('detach and close tear down and act on the port', () async {
    final c = build();
    await c.detach();
    expect(port.detached, isTrue);
    final port2 = port = FakeShellSessionPort();
    final c2 = build();
    await c2.close();
    expect(port2.closed, isTrue);
  });
}
