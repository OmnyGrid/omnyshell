import 'dart:async';
import 'dart:typed_data';

import '../../domain/backend/shell_family.dart';
import '../../domain/value_objects/session_id.dart';

/// The minimal session surface an [InteractiveShellController] drives.
///
/// [RemoteSession] satisfies this directly (its API already matches), so an
/// embedder passes its open session straight to the controller. The narrow
/// interface also makes the controller unit-testable with an in-memory fake,
/// and keeps the controller free of any transport/`dart:io` dependency.
abstract class ShellSessionPort {
  /// Remote standard-output bytes, streamed live (carries the cwd markers).
  Stream<Uint8List> get stdout;

  /// Remote standard-error bytes, streamed live.
  Stream<Uint8List> get stderr;

  /// Completes with the remote process exit code.
  Future<int> get exitCode;

  /// The remote shell's command-language family (selects the prompt dialect).
  ShellFamily get shellFamily;

  /// The session id, if known (used as the marker nonce so a resumed session
  /// derives the same completion token).
  SessionId? get id;

  /// Whether the session was detached rather than closed/exited.
  bool get wasDetached;

  /// Writes [data] to the remote standard input.
  void writeStdin(List<int> data);

  /// Resizes the remote terminal.
  void resize({required int cols, required int rows});

  /// Grants the peer [credit] more bytes of send window (flow control).
  void grantWindow(int credit);

  /// Sends `SIGINT` to the remote process (Ctrl-C).
  void interrupt();

  /// Detaches the session, keeping it alive on the node for a later resume.
  Future<void> detach();

  /// Closes the session, asking the node to terminate the process.
  Future<void> close();
}
