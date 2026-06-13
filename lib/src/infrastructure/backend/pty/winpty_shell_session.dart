import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../../domain/backend/shell_family.dart';
import '../../../domain/backend/shell_session.dart';
import 'winpty_ffi.dart';

/// A [ShellSession] backed by a real Windows pseudo-console allocated through
/// `libwinpty` (`winpty.dll`) via `dart:ffi`.
///
/// winpty exposes the child's console as two named pipes. Because a Win32
/// `HANDLE` cannot be awaited on Dart's event loop and `ReadFile` blocks, the
/// console output is pumped on a dedicated **reader isolate** and the child is
/// reaped on a tiny **waiter isolate**; raw handle integers are process-global,
/// so passing them between isolates is safe. Writes (`writeStdin`) are small and
/// done synchronously on this isolate.
///
/// Unlike the pipe fallback this is a true PTY: cooked-mode readers echo input
/// (fixing interactive prompts on Windows), full-screen apps render, and
/// [resize] actually propagates via `winpty_set_size`.
class WinptyShellSession implements ShellSession {
  final WinptyLib _winpty;
  final Kernel32 _k = Kernel32();

  /// The `winpty_t*` master; freed on teardown.
  final Pointer<Void> _wp;

  /// The spawned child process `HANDLE` (for reaping / termination).
  final Pointer<Void> _child;

  /// The opened conin (child stdin) write `HANDLE`.
  late final Pointer<Void> _conin;

  final _stdout = StreamController<Uint8List>(sync: true);
  final _exit = Completer<int>();
  final ReceivePort _readerPort = ReceivePort();
  final ReceivePort _waiterPort = ReceivePort();
  bool _disposed = false;

  WinptyShellSession({
    required WinptyLib winpty,
    required Pointer<Void> winptyPtr,
    required Pointer<Void> childHandle,
    required String coninName,
    required String conoutName,
  }) : _winpty = winpty,
       _wp = winptyPtr,
       _child = childHandle {
    // Open conin for writing (single client per pipe; the reader isolate opens
    // conout). A failure leaves an invalid handle and writes become no-ops.
    final namePtr = coninName.toNativeUtf16();
    try {
      _conin = _k.createFileW(
        namePtr,
        kGenericWrite,
        0,
        nullptr,
        kOpenExisting,
        0,
        nullptr,
      );
    } finally {
      calloc.free(namePtr);
    }

    _readerPort.listen((msg) {
      if (msg is Uint8List) {
        if (!_stdout.isClosed) _stdout.add(msg);
      } else {
        // Sentinel: conout reached EOF (child exited / pipe broke).
        if (!_stdout.isClosed) _stdout.close();
        _readerPort.close();
      }
    });
    _waiterPort.listen((msg) {
      if (msg is int && !_exit.isCompleted) _exit.complete(msg);
      _waiterPort.close();
      _dispose();
    });

    Isolate.spawn(_readerMain, (_readerPort.sendPort, conoutName));
    Isolate.spawn(_waiterMain, (_waiterPort.sendPort, _child.address));
  }

  // winpty wraps a POSIX bash here, so the client speaks the POSIX dialect.
  @override
  ShellFamily get shellFamily => ShellFamily.posix;

  @override
  int? get pid => null; // The child runs behind winpty; no Dart Process pid.

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  // A pty folds stderr into the single console stream; keep an empty, already-
  // done stream so the node's stdout/stderr drain logic stays happy.
  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void writeStdin(List<int> data) {
    if (isInvalidHandle(_conin) || data.isEmpty) return;
    final buf = calloc<Uint8>(data.length);
    final written = calloc<Uint32>();
    try {
      buf.asTypedList(data.length).setAll(0, data);
      _k.writeFile(_conin, buf, data.length, written, nullptr);
    } catch (_) {
      // The child may have exited and the pipe closed.
    } finally {
      calloc.free(buf);
      calloc.free(written);
    }
  }

  @override
  Future<void> closeStdin() async {
    // A pty has no half-close; deliver Ctrl-D so the line discipline signals
    // end-of-input to the foreground program (mirrors the script PTY session).
    writeStdin(const [0x04]);
  }

  @override
  void resize({required int cols, required int rows}) {
    if (_disposed) return;
    try {
      _winpty.setSize(_wp, cols, rows, nullptr);
    } catch (_) {
      // Best-effort: the agent may already be gone.
    }
  }

  @override
  void sendSignal(String signal) {
    final control = _controlChar(signal);
    if (control != null) {
      writeStdin([control]);
      return;
    }
    if (_processSignal(signal) && !isInvalidHandle(_child)) {
      try {
        _k.terminateProcess(_child, 1);
      } catch (_) {
        // Already gone.
      }
    }
  }

  @override
  Future<void> kill() async {
    if (!isInvalidHandle(_child)) {
      try {
        _k.terminateProcess(_child, 1);
      } catch (_) {
        // Already gone.
      }
    }
    _dispose();
  }

  /// Frees the winpty master and closes the handles we own. Idempotent.
  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_stdout.isClosed) _stdout.close();
    if (!_exit.isCompleted) _exit.complete(0);
    try {
      if (!isInvalidHandle(_conin)) _k.closeHandle(_conin);
    } catch (_) {}
    try {
      if (!isInvalidHandle(_child)) _k.closeHandle(_child);
    } catch (_) {}
    try {
      _winpty.free(_wp); // closes the agent; AUTO_SHUTDOWN reaps the child.
    } catch (_) {}
  }

  /// The control byte the line discipline turns into a signal, or `null`.
  static int? _controlChar(String name) {
    switch (name.toUpperCase()) {
      case 'SIGINT':
      case 'INT':
        return 0x03; // Ctrl-C
      case 'SIGQUIT':
      case 'QUIT':
        return 0x1c; // Ctrl-\
      case 'SIGTSTP':
      case 'TSTP':
        return 0x1a; // Ctrl-Z
      default:
        return null;
    }
  }

  /// Whether [name] is a process-wide termination signal (TERM/KILL/HUP).
  static bool _processSignal(String name) {
    switch (name.toUpperCase()) {
      case 'SIGTERM':
      case 'TERM':
      case 'SIGKILL':
      case 'KILL':
      case 'SIGHUP':
      case 'HUP':
        return true;
      default:
        return false;
    }
  }
}

/// Reader-isolate entry: open the conout named pipe and stream its bytes back
/// over [SendPort] until EOF / a broken pipe, then post a sentinel (`null`).
void _readerMain((SendPort, String) args) {
  final (sendPort, pipeName) = args;
  final k = Kernel32();
  final namePtr = pipeName.toNativeUtf16();
  final handle = k.createFileW(
    namePtr,
    kGenericRead,
    0,
    nullptr,
    kOpenExisting,
    0,
    nullptr,
  );
  calloc.free(namePtr);
  if (isInvalidHandle(handle)) {
    sendPort.send(null);
    return;
  }
  const cap = 65536;
  final buf = calloc<Uint8>(cap);
  final read = calloc<Uint32>();
  try {
    while (true) {
      final ok = k.readFile(handle, buf, cap, read, nullptr);
      final n = read.value;
      if (ok == 0 || n == 0) break; // failure or EOF
      sendPort.send(Uint8List.fromList(buf.asTypedList(n)));
    }
  } finally {
    calloc.free(buf);
    calloc.free(read);
    try {
      k.closeHandle(handle);
    } catch (_) {}
    sendPort.send(null);
  }
}

/// Waiter-isolate entry: block on the child [HANDLE] (passed as an address),
/// then post its exit code.
void _waiterMain((SendPort, int) args) {
  final (sendPort, childAddress) = args;
  final k = Kernel32();
  final child = Pointer<Void>.fromAddress(childAddress);
  final code = calloc<Uint32>();
  try {
    k.waitForSingleObject(child, kInfinite);
    final ok = k.getExitCodeProcess(child, code);
    sendPort.send(ok == 0 ? -1 : code.value);
  } finally {
    calloc.free(code);
  }
}
