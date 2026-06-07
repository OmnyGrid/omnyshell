import 'dart:typed_data';

/// A running process or shell on the node, with byte streams wired to the
/// session channel.
///
/// The node relays [stdout]/[stderr] to the client and forwards client stdin
/// via [writeStdin]. Control operations ([resize], [sendSignal]) map to the
/// matching protocol messages. The implementation is provided by a
/// [ShellBackend]; Stage 1 ships a pipe-based process backend.
abstract class ShellSession {
  /// The backend process id, if known.
  int? get pid;

  /// Bytes written by the process to standard output.
  Stream<Uint8List> get stdout;

  /// Bytes written by the process to standard error.
  Stream<Uint8List> get stderr;

  /// Completes with the process exit code once it terminates.
  Future<int> get exitCode;

  /// Writes [data] to the process's standard input.
  void writeStdin(List<int> data);

  /// Signals end-of-input on standard input (half-close).
  Future<void> closeStdin();

  /// Resizes the terminal, where the backend supports it (no-op otherwise).
  void resize({required int cols, required int rows});

  /// Sends a POSIX [signal] name (e.g. `SIGINT`, `SIGTERM`) to the process.
  void sendSignal(String signal);

  /// Forcibly terminates the process and releases resources.
  Future<void> kill();
}
