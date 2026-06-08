import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:portable_pty/portable_pty.dart';

import '../../domain/backend/shell_session.dart';

/// A [ShellSession] backed by a real pseudo-terminal via `portable_pty`.
///
/// Unlike the pipe-based [ProcessShellSession], the child runs on a controlling
/// terminal: `isatty()` is true, the kernel window size is honoured, and
/// [resize] drives `TIOCSWINSZ` live, so full-screen programs such as `nano`
/// render at the client's geometry and reflow on resize.
///
/// `portable_pty`'s `readSync` blocks until data or EOF, which would freeze the
/// event loop. Instead we poll the master fd for readiness with `poll(2)` (zero
/// timeout) on a short timer and only read when data is pending; when the
/// consumer applies backpressure (the [stdout] subscription is paused) we stop
/// draining and let the kernel pty buffer fill, throttling the child naturally.
class PtyShellSession implements ShellSession {
  final PortablePty _pty;
  final int? _pid;

  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final Completer<int> _exit = Completer<int>();
  final ffi.Pointer<_PollFd> _pollFd;

  Timer? _timer;
  bool _finished = false;

  PtyShellSession._(this._pty, this._pid, this._pollFd) {
    _pollFd.ref
      ..fd = _pty.masterFd
      ..events = _pollIn
      ..revents = 0;
    _timer = Timer.periodic(_pollInterval, (_) => _tick());
  }

  /// Wraps an already-`spawn`ed [PortablePty]. The PTY must expose a valid POSIX
  /// master fd (`masterFd >= 0`); callers gate this on non-Windows platforms.
  factory PtyShellSession(PortablePty pty, {int? pid}) =>
      PtyShellSession._(pty, pid, calloc<_PollFd>());

  static const _pollInterval = Duration(milliseconds: 8);
  // Cap reads per tick (64 × 64 KiB = 4 MiB) so a firehose cannot starve the
  // event loop; the remainder is drained on the next tick.
  static const _maxReadsPerTick = 64;

  @override
  int? get pid => _pid;

  @override
  Stream<Uint8List> get stdout => _out.stream;

  // A PTY merges the child's stderr into the single master stream, so there is
  // no separate stderr channel; an empty (immediately-done) stream keeps the
  // node's stdout/stderr drain logic happy.
  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  Future<int> get exitCode => _exit.future;

  void _tick() {
    if (_finished) return;
    // Honour backpressure: while the consumer is paused, leave bytes in the
    // kernel pty buffer (the child blocks on write) instead of buffering here.
    if (_out.isPaused) return;

    var eof = false;
    for (var i = 0; i < _maxReadsPerTick; i++) {
      if (_out.isPaused) return;
      if (!_readable()) break;
      Uint8List chunk;
      try {
        chunk = _pty.readSync(65536);
      } on Object {
        eof = true;
        break;
      }
      if (chunk.isEmpty) {
        eof = true;
        break;
      }
      _out.add(chunk);
    }
    if (eof) _finish(_pty.tryWait() ?? _safeWait());
  }

  /// `poll(fd, POLLIN, 0)`: returns true when the master fd has bytes pending or
  /// has hung up (child exited) — in which case the following `readSync`
  /// returns the remaining bytes, then empty (EOF).
  bool _readable() {
    _pollFd.ref.revents = 0;
    final ret = _poll(_pollFd, 1, 0);
    if (ret <= 0) return false;
    return _pollFd.ref.revents & (_pollIn | _pollHup | _pollErr | _pollNval) !=
        0;
  }

  int _safeWait() {
    try {
      return _pty.wait();
    } on Object {
      return -1;
    }
  }

  @override
  void writeStdin(List<int> data) {
    if (_finished) return;
    try {
      _pty.writeBytes(Uint8List.fromList(data));
    } on Object {
      // The child may have exited and closed the slave.
    }
  }

  @override
  Future<void> closeStdin() async {
    // A PTY has no half-close; deliver the terminal EOF character (Ctrl-D) so
    // the line discipline signals end-of-input to the foreground program.
    if (_finished) return;
    try {
      _pty.writeBytes(Uint8List.fromList(const [0x04]));
    } on Object {
      // Ignore: child already gone.
    }
  }

  @override
  void resize({required int cols, required int rows}) {
    if (_finished) return;
    try {
      _pty.resize(rows: rows, cols: cols);
    } on Object {
      // Ignore: child already gone.
    }
  }

  @override
  void sendSignal(String signal) {
    if (_finished) return;
    final sig = _signalNumber(signal);
    if (sig == null) return;
    try {
      _pty.kill(sig);
    } on Object {
      // Ignore: child already gone.
    }
  }

  @override
  Future<void> kill() async {
    if (_finished) return;
    try {
      _pty.kill(9); // SIGKILL
    } on Object {
      // Ignore.
    }
    _finish(_pty.tryWait() ?? -1);
  }

  void _finish(int code) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    if (!_out.isClosed) unawaited(_out.close());
    if (!_exit.isCompleted) _exit.complete(code);
    try {
      _pty.close();
    } on Object {
      // Ignore: already closed.
    }
    calloc.free(_pollFd);
  }

  static int? _signalNumber(String name) {
    switch (name.toUpperCase()) {
      case 'SIGHUP':
      case 'HUP':
        return 1;
      case 'SIGINT':
      case 'INT':
        return 2;
      case 'SIGQUIT':
      case 'QUIT':
        return 3;
      case 'SIGKILL':
      case 'KILL':
        return 9;
      case 'SIGTERM':
      case 'TERM':
        return 15;
      default:
        return null;
    }
  }
}

// --- poll(2) FFI -------------------------------------------------------------

const int _pollIn = 0x0001;
const int _pollErr = 0x0008;
const int _pollHup = 0x0010;
const int _pollNval = 0x0020;

// struct pollfd { int fd; short events; short revents; }
final class _PollFd extends ffi.Struct {
  @ffi.Int32()
  external int fd;
  @ffi.Int16()
  external int events;
  @ffi.Int16()
  external int revents;
}

typedef _PollNative =
    ffi.Int Function(ffi.Pointer<_PollFd>, ffi.UnsignedLong, ffi.Int);
typedef _PollDart = int Function(ffi.Pointer<_PollFd>, int, int);

final _PollDart _poll = ffi.DynamicLibrary.process()
    .lookupFunction<_PollNative, _PollDart>('poll');
