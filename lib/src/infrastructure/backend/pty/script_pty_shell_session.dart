import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../domain/backend/shell_session.dart';

/// A [ShellSession] backed by a real pseudo-terminal allocated by the system
/// `script(1)` utility, which runs as an ordinary child [Process].
///
/// Unlike the FFI-based `PtyShellSession` (which loads the `portable_pty` native
/// library), all PTY ownership — `forkpty`, the controlling terminal and signal
/// handling — lives inside the `script` process. The node only does pipe I/O and
/// reaps a normal child, so this backend cannot trigger the native `SIGCHLD`
/// crash that affects `portable_pty`.
///
/// `script` bridges the child's tty to its own stdin/stdout, so:
/// - [stdout] is the merged terminal output (the pty folds stderr into stdout);
/// - [writeStdin] feeds the child's tty input;
/// - [exitCode] is the child's exit status, surfaced by `script`.
///
/// Limitation: `script` launched from pipes has no controlling terminal of its
/// own, so [resize] cannot propagate to the child and is a no-op. The initial
/// geometry is seeded once by the backend (via `stty rows/cols` before `exec`).
class ScriptPtyShellSession implements ShellSession {
  final Process _process;

  /// Wraps an already-started `script` [Process].
  ScriptPtyShellSession(this._process);

  @override
  int? get pid => _process.pid;

  @override
  Stream<Uint8List> get stdout =>
      _process.stdout.map((chunk) => Uint8List.fromList(chunk));

  // A PTY merges the child's stderr into the single master stream, so there is
  // no separate stderr channel; an empty (immediately-done) stream keeps the
  // node's stdout/stderr drain logic happy.
  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void writeStdin(List<int> data) {
    try {
      _process.stdin.add(data);
    } on Object {
      // The child may have exited and `script` closed its stdin.
    }
  }

  @override
  Future<void> closeStdin() async {
    // A PTY has no half-close; deliver the terminal EOF character (Ctrl-D) so
    // the line discipline signals end-of-input to the foreground program.
    try {
      _process.stdin.add(const [0x04]);
    } on Object {
      // Ignore: child already gone.
    }
  }

  @override
  void resize({required int cols, required int rows}) {
    // No-op: `script` started from pipes has no controlling terminal whose
    // SIGWINCH it could follow, and the node cannot reach the child's tty to
    // update its window size. Live resize requires the native PTY backend.
  }

  @override
  void sendSignal(String signal) {
    // Interactive signals are delivered the terminal-native way: writing the
    // control character lets the pty line discipline raise the signal for the
    // foreground process group (honouring whatever mode the program set).
    final control = _controlChar(signal);
    if (control != null) {
      writeStdin([control]);
      return;
    }
    // Process-wide signals (TERM/KILL/HUP) go to `script`, which relays the
    // hangup to the child when its master closes.
    final sig = _processSignal(signal);
    if (sig != null) {
      try {
        _process.kill(sig);
      } on Object {
        // Ignore: child already gone.
      }
    }
  }

  @override
  Future<void> kill() async {
    try {
      _process.kill(ProcessSignal.sigkill);
    } on Object {
      // Ignore.
    }
    try {
      await _process.stdin.close();
    } on Object {
      // Ignore: stdin already closed.
    }
  }

  /// The control byte that the line discipline turns into a signal, or `null`
  /// for signals without a terminal control character.
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

  static ProcessSignal? _processSignal(String name) {
    switch (name.toUpperCase()) {
      case 'SIGTERM':
      case 'TERM':
        return ProcessSignal.sigterm;
      case 'SIGKILL':
      case 'KILL':
        return ProcessSignal.sigkill;
      case 'SIGHUP':
      case 'HUP':
        return ProcessSignal.sighup;
      default:
        return null;
    }
  }
}
