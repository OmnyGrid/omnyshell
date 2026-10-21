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
  // The exit-code-carrying agent marker: a 5th tab field after cwd.
  String agentMarkerLine(String cwd, int ec) =>
      '${marker.token}$cwd\t\t\t\t$ec\n';

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

  test('submitLine expands the `l` shortcut for the shell', () async {
    final c = build();
    port.emitStdout(utf8.encode(markerLine('/home/alice')));
    await pump();
    port.stdin.clear();

    c.submitLine('l /tmp');
    expect(sent(), contains("eval 'ls -alh /tmp'"));
  });

  test('`l` is read-only, so it is followed by the ping marker', () async {
    final c = build();
    port.emitStdout(utf8.encode(markerLine('/home/alice')));
    await pump();
    port.stdin.clear();

    c.submitLine('l');
    final cmd = sent();
    expect(cmd, contains(marker.pingCommand));
    expect(cmd, isNot(contains(marker.command)));
  });

  test('`l` expands to Get-ChildItem on a PowerShell session', () async {
    port = FakeShellSessionPort(shellFamily: ShellFamily.powershell);
    final c = build();
    port.stdin.clear();

    c.submitLine('l');
    expect(sent(), startsWith('Get-ChildItem -Force | Format-Table '));
  });

  test('`l` expands to dir /a on a cmd session', () async {
    port = FakeShellSessionPort(shellFamily: ShellFamily.cmd);
    final c = build();
    port.stdin.clear();

    c.submitLine('l');
    expect(sent(), startsWith('dir /a & '));
  });

  test('runAgentCommand does not expand the `l` shortcut', () async {
    final c = build();
    port.emitStdout(utf8.encode(markerLine('/home/alice')));
    await pump();
    port.stdin.clear();

    unawaited(c.runAgentCommand('l').catchError((_) => ShellRunResult([], 0)));
    expect(sent(), contains("eval 'l'"));
  });

  test(
    'runAgentCommand dispatches, captures output + exit code, and tees it',
    () async {
      final c = build();
      port.emitStdout(utf8.encode(markerLine('/home/alice')));
      await pump();
      port.stdin.clear();

      final future = c.runAgentCommand('whoami');
      expect(passthrough.last, isTrue); // owns the terminal while it runs
      final cmd = sent();
      expect(cmd, contains("eval 'whoami'"));
      expect(cmd, contains(r'__omny_ec=$?')); // exit-code-capturing marker

      port.emitStdout(
        utf8.encode('alice\n${agentMarkerLine('/home/alice', 0)}'),
      );
      final result = await future;

      expect(
        utf8.decode(result.output, allowMalformed: true),
        contains('alice'),
      );
      expect(result.exitCode, 0);
      expect(passthrough.last, isFalse); // returned to prompt
      // Output also streamed live to onOutput (the user sees it).
      expect(utf8.decode(output, allowMalformed: true), contains('alice'));
    },
  );

  test('runAgentCommand captures stderr and a non-zero exit code', () async {
    final c = build();
    port.emitStdout(utf8.encode(markerLine('/home/alice')));
    await pump();

    final future = c.runAgentCommand('sudo apt-get update');
    port.emitStderr(utf8.encode('E: permission denied\n'));
    port.emitStdout(utf8.encode(agentMarkerLine('/home/alice', 1)));
    final result = await future;

    expect(
      utf8.decode(result.output, allowMalformed: true),
      contains('permission denied'),
    );
    expect(result.exitCode, 1);
  });

  test(
    'runAgentCommand rejects while a command is already in flight',
    () async {
      final c = build();
      port.emitStdout(utf8.encode(markerLine('/home/alice')));
      await pump();

      final first = c.runAgentCommand('sleep 1');
      await expectLater(c.runAgentCommand('ls'), throwsStateError);
      // finish the first so the test doesn't leave a dangling future
      port.emitStdout(utf8.encode(agentMarkerLine('/home/alice', 0)));
      await first;
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

  group('PowerShell echo', () {
    // PowerShell reading a pipe writes its prompt before every line it reads,
    // then echoes the line.
    const dialect = PowerShellDialect();

    // Whether PowerShell has written anything yet (the first prompt is the
    // default one: the init line, which sets the sentinel, has not run), and
    // whether the prompt for the next line is already out (it is written as
    // soon as PowerShell is ready for a line, before the line is sent).
    var started = false;
    var prompted = false;

    setUp(() {
      port = FakeShellSessionPort(shellFamily: ShellFamily.powershell);
      started = false;
      prompted = false;
    });

    String promptFor({required bool first}) =>
        first ? r'PS C:\Users\u> ' : marker.promptSentinel;

    /// What PowerShell sends back for the lines the client sent so far, as
    /// recorded on CI (`powershell_pipe_test`): each line echoed after the
    /// prompt, `\n`-terminated; then [then]; then the prompt for the next
    /// line.
    void echoSentLinesThen(String then) {
      final lines = sent().split('\n').where((l) => l.isNotEmpty).toList();
      final echoed = StringBuffer();
      for (var i = 0; i < lines.length; i++) {
        if (!(i == 0 && prompted)) {
          echoed.write(promptFor(first: !started));
        }
        started = true;
        echoed.write('${lines[i]}\n');
      }
      port.stdin.clear();
      port.emitStdout(utf8.encode('$echoed$then${promptFor(first: false)}'));
      prompted = true;
    }

    test('the init line and first marker are not shown', () async {
      build();
      echoSentLinesThen(markerLine(r'C:\Users\u'));
      await pump();
      expect(utf8.decode(output), isEmpty);
      expect(prompts.single.cwd, r'C:\Users\u');
    });

    test('a command\'s echo is dropped, its output kept', () async {
      final c = build();
      echoSentLinesThen(markerLine(r'C:\Users\u'));
      await pump();
      c.submitLine('ls');
      expect(sent(), matches(RegExp(r'^ls +; '))); // the marker rides along
      echoSentLinesThen(
        '\r\n    Directory: C:\\Users\\u\r\n\r\nMode  Name\r\n'
        '${marker.token}\n',
      );
      await pump();
      final shown = utf8.decode(output);
      expect(shown, isNot(contains('ls ;')));
      expect(shown, isNot(contains('[Console]::Out')));
      expect(shown, contains('Directory: C:\\Users\\u'));
      expect(shown, contains('Mode  Name'));
      expect(prompts, hasLength(2));
    });

    test('an echo split across chunks is still dropped', () async {
      final c = build();
      echoSentLinesThen(markerLine(r'C:\'));
      await pump();
      c.submitLine('whoami');
      final line = sent().trimRight();
      port.stdin.clear();
      port
        ..emitStdout(utf8.encode(line.substring(0, 10)))
        ..emitStdout(utf8.encode('${line.substring(10)}\r'))
        ..emitStdout(utf8.encode('\ndesktop\\u\r\n${marker.token}\n'));
      await pump();
      expect(utf8.decode(output), 'desktop\\u\r\n');
    });

    test('a PowerShell that does not echo loses no output', () async {
      final c = build();
      // No echo at all (as PowerShell 7 may behave).
      port.emitStdout(utf8.encode(markerLine(r'C:\')));
      await pump();
      c.submitLine('ls');
      port.stdin.clear();
      port.emitStdout(utf8.encode('l'));
      await pump();
      // Not held back as a possible echo: the filter switched itself off.
      expect(utf8.decode(output), 'l');
    });

    test('the dialect says it echoes; POSIX does not', () {
      expect(dialect.echoesInput, isTrue);
      expect(const PosixShellDialect().echoesInput, isFalse);
    });

    test('an agent command\'s captured output holds no echo', () async {
      final c = build();
      echoSentLinesThen(markerLine(r'C:\'));
      await pump();
      final run = c.runAgentCommand('Get-Date');
      echoSentLinesThen('Tuesday\r\n${agentMarkerLine(r'C:\', 0)}');
      final result = await run;
      expect(utf8.decode(result.output), 'Tuesday\r\n');
      expect(result.exitCode, 0);
      expect(utf8.decode(output), isNot(contains('Get-Date')));
    });

    test(
      'input typed into a running program is not taken for an echo',
      () async {
        final c = build();
        echoSentLinesThen(markerLine(r'C:\'));
        await pump();
        c.submitLine(r'Read-Host "Name"');
        // The line's echo (after the prompt already written), then Read-Host's
        // own prompt: no PowerShell prompt while the command runs.
        final line = sent().trimRight();
        port.stdin.clear();
        port.emitStdout(utf8.encode('$line\nName: '));
        await pump();
        // The user answers the prompt; PowerShell's Read-Host shows the answer.
        c.sendRaw(utf8.encode('alice\n'));
        port.emitStdout(utf8.encode('alice\r\nalice\r\n${marker.token}\n'));
        await pump();
        expect(utf8.decode(output), 'Name: alice\r\nalice\r\n');
      },
    );

    test('stderr is never filtered', () async {
      final errors = <int>[];
      port = FakeShellSessionPort(shellFamily: ShellFamily.powershell);
      final c = InteractiveShellController(
        session: port,
        marker: marker,
        onOutput: (_) {},
        onStderr: errors.addAll,
        onPrompt: (_) {},
        onPassthrough: (_) {},
      )..start();
      c.submitLine('bad-command');
      final line = sent().split('\n').lastWhere((l) => l.isNotEmpty);
      port.emitStderr(utf8.encode('$line\r\n'));
      await pump();
      expect(utf8.decode(errors), '$line\r\n');
    });

    test('a resumed session filters the echoes of what it sends', () async {
      // Resumed inside a full-screen program: nothing is sent at start, so
      // the first completion has no echo to see — which must not switch the
      // filter off.
      final c = build(resumedInAltScreen: true);
      started = true; // set up in an earlier connection: sentinel prompt
      expect(sent(), isEmpty);
      port.emitStdout(utf8.encode(markerLine(r'C:\')));
      await pump();
      // The resume fetches the cwd with a full marker, which is echoed.
      echoSentLinesThen(markerLine(r'C:\Users\u'));
      await pump();
      c.submitLine('whoami');
      echoSentLinesThen('desktop\\u\r\n${marker.token}\n');
      await pump();
      expect(utf8.decode(output), 'desktop\\u\r\n');
    });

    test(
      'the first echoes after PowerShell\'s default prompt are dropped',
      () async {
        // Until the init line has run, PowerShell prints its default
        // `PS C:\…> ` before the line it reads, so the init line's echo
        // follows it; the init line then makes the prompt the sentinel.
        final c = build();
        final lines = sent().split('\n').where((l) => l.isNotEmpty).toList();
        expect(lines.first, dialect.sessionInitLine(marker));
        port.stdin.clear();
        port.emitStdout(
          utf8.encode(
            'PS C:\\Users\\u> ${lines[0]}\r\n'
            '${marker.promptSentinel}${lines[1]}\n'
            '${markerLine(r'C:\Users\u')}${marker.promptSentinel}',
          ),
        );
        await pump();
        expect(utf8.decode(output), isEmpty);
        // The filter keeps working for the commands that follow.
        started = prompted = true;
        c.submitLine('whoami');
        echoSentLinesThen('desktop\\u\r\n${marker.token}\n');
        await pump();
        expect(utf8.decode(output), 'desktop\\u\r\n');
      },
    );

    test('a resumed session fetching its cwd keeps filtering echoes', () async {
      // Resumed into a full-screen program whose queued marker is a ping
      // (no cwd): its completion sends a full marker to fetch the cwd. That
      // line is the next command's, not the completed one's.
      final c = build(resumedInAltScreen: true);
      started = true; // set up in an earlier connection: sentinel prompt
      port.emitStdout(utf8.encode('${marker.token}\n')); // the ping
      await pump();
      expect(sent(), contains('[Console]::Out')); // the cwd fetch
      echoSentLinesThen(markerLine(r'C:\Users\u'));
      await pump();
      expect(utf8.decode(output), isEmpty);
      expect(prompts.last.cwd, r'C:\Users\u');
      c.submitLine('whoami');
      echoSentLinesThen('desktop\\u\r\n${marker.token}\n');
      await pump();
      expect(utf8.decode(output), 'desktop\\u\r\n');
    });

    test('an echo in another encoding is shown rather than held', () async {
      // Windows PowerShell may echo non-ASCII text in the console code page,
      // not UTF-8: the bytes then differ, and the line must pass through.
      final c = build();
      echoSentLinesThen(markerLine(r'C:\'));
      await pump();
      c.submitLine('echo ação');
      final line = sent().split('\n').firstWhere((l) => l.isNotEmpty);
      port.stdin.clear();
      port.emitStdout([
        ...latin1.encode(line),
        13,
        10,
        ...utf8.encode('ação\r\n${marker.token}\n'),
      ]);
      await pump();
      final shown = utf8.decode(output, allowMalformed: true);
      expect(shown, contains('ação\r\n'));
      expect(prompts, hasLength(2));
    });
  });
}
