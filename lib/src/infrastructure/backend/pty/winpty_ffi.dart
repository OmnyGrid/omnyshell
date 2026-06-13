/// Minimal `dart:ffi` bindings for `libwinpty` (`winpty.dll`, shipped with Git
/// for Windows) and the handful of `kernel32` calls needed to drive its named
/// pipes. Hand-rolled (no `win32` package) to keep the dependency footprint
/// lean; the ABIs used here are stable.
///
/// Only the surface `WinptyShellBackend`/`WinptyShellSession` need is bound. The
/// CLI front-end (`winpty.exe`) is unusable from pipe-backed stdio because it
/// derives geometry from `ioctl(STDIN, TIOCGWINSZ)` and asserts on 0×0; calling
/// the library directly with an explicit size avoids that entirely.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// --- winpty agent / spawn flags -------------------------------------------

/// Kill the spawned process when the winpty master (agent) shuts down.
const int kWinptySpawnFlagAutoShutdown = 0x1;

// --- kernel32 constants ----------------------------------------------------

const int kGenericRead = 0x80000000;
const int kGenericWrite = 0x40000000;
const int kOpenExisting = 3;
const int kInfinite = 0xFFFFFFFF;
const int kErrorBrokenPipe = 109;
const int kWaitObject0 = 0x0;

/// A Win32 `HANDLE` is invalid when it is `INVALID_HANDLE_VALUE` (-1 on 64-bit
/// Dart ints), `0xFFFFFFFF`, or null.
bool isInvalidHandle(Pointer<Void> h) =>
    h.address == -1 || h.address == 0xFFFFFFFF || h.address == 0;

// --- winpty.dll ------------------------------------------------------------

/// Bindings for `winpty.dll`. Instantiate once on the owning isolate.
class WinptyLib {
  final DynamicLibrary _lib;

  WinptyLib(String dllPath) : _lib = DynamicLibrary.open(dllPath);

  late final configNew = _lib
      .lookupFunction<
        Pointer<Void> Function(Uint64, Pointer<Pointer<Void>>),
        Pointer<Void> Function(int, Pointer<Pointer<Void>>)
      >('winpty_config_new');

  late final configSetInitialSize = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32, Int32),
        void Function(Pointer<Void>, int, int)
      >('winpty_config_set_initial_size');

  late final configFree = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('winpty_config_free');

  late final open = _lib
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
      >('winpty_open');

  late final coninName = _lib
      .lookupFunction<
        Pointer<Utf16> Function(Pointer<Void>),
        Pointer<Utf16> Function(Pointer<Void>)
      >('winpty_conin_name');

  late final conoutName = _lib
      .lookupFunction<
        Pointer<Utf16> Function(Pointer<Void>),
        Pointer<Utf16> Function(Pointer<Void>)
      >('winpty_conout_name');

  late final spawnConfigNew = _lib
      .lookupFunction<
        Pointer<Void> Function(
          Uint64,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Pointer<Void>>,
        ),
        Pointer<Void> Function(
          int,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Pointer<Void>>,
        )
      >('winpty_spawn_config_new');

  late final spawnConfigFree = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('winpty_spawn_config_free');

  late final spawn = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
          Pointer<Pointer<Void>>,
        )
      >('winpty_spawn');

  late final setSize = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Int32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, int, Pointer<Pointer<Void>>)
      >('winpty_set_size');

  late final free = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('winpty_free');

  late final errorCode = _lib
      .lookupFunction<
        Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('winpty_error_code');

  late final errorMsg = _lib
      .lookupFunction<
        Pointer<Utf16> Function(Pointer<Void>),
        Pointer<Utf16> Function(Pointer<Void>)
      >('winpty_error_msg');

  late final errorFree = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('winpty_error_free');

  /// Reads a winpty error out-pointer into a human string (empty when unset)
  /// and frees it, leaving `*errPtr` null.
  String drainError(Pointer<Pointer<Void>> errPtr) {
    final err = errPtr.value;
    if (err.address == 0) return '';
    final code = errorCode(err);
    final msgPtr = errorMsg(err);
    final msg = msgPtr.address == 0 ? '' : msgPtr.toDartString();
    errorFree(err);
    errPtr.value = nullptr;
    return 'winpty error $code: $msg';
  }
}

// --- kernel32.dll ----------------------------------------------------------

/// Bindings for the `kernel32` calls used to read/write winpty's named pipes
/// and reap the child. Each isolate that does pipe I/O instantiates its own
/// (a [DynamicLibrary] is not shareable across isolates, but raw `HANDLE`
/// integers are process-global and safe to pass between them).
class Kernel32 {
  final DynamicLibrary _lib;

  Kernel32() : _lib = DynamicLibrary.open('kernel32.dll');

  late final createFileW = _lib
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');

  late final readFile = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('ReadFile');

  late final writeFile = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('WriteFile');

  late final closeHandle = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');

  late final waitForSingleObject = _lib
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');

  late final getExitCodeProcess = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint32>)
      >('GetExitCodeProcess');

  late final terminateProcess = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('TerminateProcess');

  late final getLastError = _lib
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
}

/// Builds a Win32 environment block (`KEY=VALUE\0KEY=VALUE\0\0`, UTF-16) from
/// [env], allocated with [calloc]. Caller frees with `calloc.free`. Returns
/// `nullptr` for an empty map (child then inherits the agent's environment).
Pointer<Utf16> buildEnvironmentBlock(Map<String, String> env) {
  if (env.isEmpty) return nullptr;
  final buffer = StringBuffer();
  env.forEach((k, v) {
    buffer
      ..write(k)
      ..write('=')
      ..write(v)
      ..writeCharCode(0);
  });
  buffer.writeCharCode(0); // final terminator
  final units = buffer.toString().codeUnits;
  final ptr = calloc<Uint16>(units.length);
  final list = ptr.asTypedList(units.length);
  list.setAll(0, units);
  return ptr.cast<Utf16>();
}
