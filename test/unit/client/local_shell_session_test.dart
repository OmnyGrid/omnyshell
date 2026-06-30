import 'dart:async';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// A recording [ShellSession] so [LocalShellSession]'s mapping can be asserted
/// without spawning a real process.
class _FakeShellSession implements ShellSession {
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _exit = Completer<int>();
  final List<List<int>> writes = [];
  final List<String> signals = [];
  ({int cols, int rows})? lastResize;
  bool killed = false;
  bool stdinClosed = false;

  @override
  int? get pid => 4242;

  @override
  ShellFamily get shellFamily => ShellFamily.posix;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void writeStdin(List<int> data) => writes.add(data);

  @override
  Future<void> closeStdin() async => stdinClosed = true;

  @override
  void resize({required int cols, required int rows}) =>
      lastResize = (cols: cols, rows: rows);

  @override
  void sendSignal(String signal) => signals.add(signal);

  @override
  Future<void> kill() async {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
  }

  void emitStdout(List<int> bytes) => _stdout.add(Uint8List.fromList(bytes));
  void exit(int code) => _exit.complete(code);
}

void main() {
  group('LocalShellSession', () {
    test('passes stdout/exitCode/shellFamily through', () async {
      final shell = _FakeShellSession();
      final session = LocalShellSession(shell);

      expect(session.shellFamily, ShellFamily.posix);

      final received = <int>[];
      final sub = session.stdout.listen(received.addAll);
      shell.emitStdout([1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      expect(received, [1, 2, 3]);

      shell.exit(7);
      expect(await session.exitCode, 7);
      await sub.cancel();
    });

    test('forwards writeStdin and resize', () {
      final shell = _FakeShellSession();
      final session = LocalShellSession(shell);

      session.writeStdin([9, 8]);
      session.resize(cols: 120, rows: 40);

      expect(shell.writes, [
        [9, 8],
      ]);
      expect(shell.lastResize, (cols: 120, rows: 40));
    });

    test(
      'interrupt() sends SIGINT, close() kills, closeStdin() half-closes',
      () async {
        final shell = _FakeShellSession();
        final session = LocalShellSession(shell);

        session.interrupt();
        expect(shell.signals, ['SIGINT']);

        await session.closeStdin();
        expect(shell.stdinClosed, isTrue);

        await session.close();
        expect(shell.killed, isTrue);
      },
    );

    test('transport-only ops are no-ops and it never detaches', () async {
      final shell = _FakeShellSession();
      final session = LocalShellSession(shell);

      expect(session.wasDetached, isFalse);
      // grantWindow / detach must not throw.
      session.grantWindow(1024);
      await session.detach();
      expect(session.wasDetached, isFalse);
    });

    test('mints a stable, non-null session id', () {
      final session = LocalShellSession(_FakeShellSession());
      final id = session.id;
      expect(id, isNotNull);
      expect(session.id, same(id)); // stable across reads
    });
  });
}
