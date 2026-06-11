import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell.dart';

/// A [ShellBackend] that produces controllable [FakeShellSession]s instead of
/// spawning real processes, for deterministic relay/streaming tests.
class FakeShellBackend implements ShellBackend {
  /// All sessions started, in order.
  final List<FakeShellSession> sessions = [];

  /// The most recent request handed to [start].
  ShellRequest? lastRequest;

  /// Optional override to fail the next [start].
  bool failNext = false;

  @override
  Future<ShellSession> start(ShellRequest request) async {
    lastRequest = request;
    if (failNext) {
      failNext = false;
      throw StateError('backend refused');
    }
    final session = FakeShellSession();
    sessions.add(session);
    return session;
  }
}

/// A scriptable [ShellSession] used by [FakeShellBackend].
class FakeShellSession implements ShellSession {
  final StreamController<Uint8List> _stdout = StreamController<Uint8List>();
  final StreamController<Uint8List> _stderr = StreamController<Uint8List>();
  final Completer<int> _exit = Completer<int>();

  /// Bytes written to stdin by the node.
  final BytesBuilder receivedStdin = BytesBuilder(copy: false);

  /// Recorded resize requests as `(cols, rows)`.
  final List<(int, int)> resizes = [];

  /// Recorded signal names.
  final List<String> signals = [];

  /// Whether stdin has been closed.
  bool stdinClosed = false;

  /// Whether [kill] has been called (the PTY/shell was terminated).
  bool killed = false;

  /// The shell family this fake reports; overridable per test.
  @override
  ShellFamily shellFamily = ShellFamily.posix;

  @override
  int? get pid => 4242;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  /// Emits [text] on stdout.
  void emitStdout(String text) =>
      _stdout.add(Uint8List.fromList(utf8.encode(text)));

  /// Emits [text] on stderr.
  void emitStderr(String text) =>
      _stderr.add(Uint8List.fromList(utf8.encode(text)));

  /// Completes the session with [code], closing the output streams.
  Future<void> complete(int code) async {
    await _stdout.close();
    await _stderr.close();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  /// The stdin received so far, decoded as UTF-8.
  String get receivedStdinText =>
      utf8.decode(receivedStdin.toBytes(), allowMalformed: true);

  @override
  void writeStdin(List<int> data) => receivedStdin.add(data);

  @override
  Future<void> closeStdin() async => stdinClosed = true;

  @override
  void resize({required int cols, required int rows}) =>
      resizes.add((cols, rows));

  @override
  void sendSignal(String signal) => signals.add(signal);

  @override
  Future<void> kill() async {
    killed = true;
    if (!_stdout.isClosed) await _stdout.close();
    if (!_stderr.isClosed) await _stderr.close();
    if (!_exit.isCompleted) _exit.complete(-1);
  }
}
