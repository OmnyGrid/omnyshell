import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/backend/shell_session.dart';

/// A [ShellSession] backed by an OS process started with [Process.start].
///
/// stdin/stdout/stderr are wired through pipes. This backend does not allocate a
/// real PTY, so [resize] is a no-op; a future PTY-backed session can replace it
/// without changing callers.
class ProcessShellSession implements ShellSession {
  final Process _process;

  /// Wraps an already-started OS [Process].
  ProcessShellSession(this._process);

  @override
  int? get pid => _process.pid;

  @override
  Stream<Uint8List> get stdout =>
      _process.stdout.map((chunk) => Uint8List.fromList(chunk));

  @override
  Stream<Uint8List> get stderr =>
      _process.stderr.map((chunk) => Uint8List.fromList(chunk));

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void writeStdin(List<int> data) {
    try {
      _process.stdin.add(data);
    } on Object {
      // The process may have already exited and closed stdin.
    }
  }

  @override
  Future<void> closeStdin() async {
    try {
      await _process.stdin.close();
    } on Object {
      // Ignore: stdin already closed.
    }
  }

  @override
  void resize({required int cols, required int rows}) {
    // No-op for the pipe-based backend (no controlling terminal).
  }

  @override
  void sendSignal(String signal) {
    final sig = _signalFromName(signal);
    if (sig != null) {
      _process.kill(sig);
    }
  }

  @override
  Future<void> kill() async {
    _process.kill(ProcessSignal.sigkill);
    try {
      await _process.stdin.close();
    } on Object {
      // Ignore.
    }
  }

  static ProcessSignal? _signalFromName(String name) {
    switch (name.toUpperCase()) {
      case 'SIGINT':
      case 'INT':
        return ProcessSignal.sigint;
      case 'SIGTERM':
      case 'TERM':
        return ProcessSignal.sigterm;
      case 'SIGKILL':
      case 'KILL':
        return ProcessSignal.sigkill;
      case 'SIGHUP':
      case 'HUP':
        return ProcessSignal.sighup;
      case 'SIGQUIT':
      case 'QUIT':
        return ProcessSignal.sigquit;
      default:
        return null;
    }
  }
}
