import 'dart:async';
import 'dart:typed_data';

import '../../domain/entities/session.dart';
import '../../domain/value_objects/session_id.dart';
import '../../protocol/channel.dart';
import '../../protocol/control_message.dart';
import '../../shared/errors/omnyshell_exception.dart';

/// A client-side handle to one open session on a node.
///
/// Wraps the session's [Channel]: writes go to the remote stdin, [stdout] and
/// [stderr] stream the remote output in real time, and [exitCode] completes
/// when the remote process exits. Control helpers ([resize], [interrupt],
/// [sendSignal], [sendEof]) issue the matching protocol messages.
class RemoteSession {
  /// Exec or interactive shell.
  final SessionMode mode;

  final Channel _channel;
  final Completer<void> _opened = Completer<void>();
  final Completer<int> _exit = Completer<int>();
  late final StreamSubscription<ControlMessage> _controlSub;
  SessionId? _id;

  /// Creates a remote-session handle over the given channel.
  RemoteSession(this._channel, this.mode) {
    _controlSub = _channel.control.listen(_onControl);
  }

  /// The session id (available once [opened] completes).
  SessionId? get id => _id;

  /// Completes once the node confirms the session is open, or completes with a
  /// [SessionRejectedException] if it was refused.
  Future<void> get opened => _opened.future;

  /// Remote standard output bytes, streamed live.
  Stream<Uint8List> get stdout => _channel.stdout;

  /// Remote standard error bytes, streamed live.
  Stream<Uint8List> get stderr => _channel.stderr;

  /// Completes with the remote process exit code (or `-1` if the session closed
  /// without a clean exit).
  Future<int> get exitCode => _exit.future;

  /// Writes [data] to the remote standard input.
  void writeStdin(List<int> data) => _channel.sendStdin(data);

  /// Bytes queued locally awaiting send credit (for transfer backpressure).
  int get queuedBytes => _channel.queuedBytes;

  /// Grants the peer [credit] more bytes of send window (transfer flow control).
  void grantWindow(int credit) => _channel.sendControl(
    ChannelWindow(channel: _channel.id, stream: 'stdout', credit: credit),
  );

  /// Signals end-of-input on the remote standard input.
  void sendEof() =>
      _channel.sendControl(ChannelEof(channel: _channel.id, stream: 'stdin'));

  /// Resizes the remote terminal.
  void resize({required int cols, required int rows}) => _channel.sendControl(
    ChannelResize(channel: _channel.id, cols: cols, rows: rows),
  );

  /// Sends `SIGINT` to the remote process (Ctrl+C).
  void interrupt() => sendSignal('SIGINT');

  /// Sends the named POSIX [signal] to the remote process.
  void sendSignal(String signal) =>
      _channel.sendControl(ChannelSignal(channel: _channel.id, signal: signal));

  void _onControl(ControlMessage message) {
    switch (message) {
      case final SessionOpened opened:
        _id = SessionId(opened.sessionId);
        if (!_opened.isCompleted) _opened.complete();
      case final SessionRejected rejected:
        if (!_opened.isCompleted) {
          _opened.completeError(
            SessionRejectedException(rejected.message, code: rejected.reason),
          );
        }
      case final ChannelExit exit:
        if (!_exit.isCompleted) _exit.complete(exit.exitCode);
      case final ChannelClose _:
        _completeClosed();
      default:
        break;
    }
  }

  void _completeClosed() {
    if (!_opened.isCompleted) {
      _opened.completeError(
        const SessionRejectedException('Session closed before opening'),
      );
    }
    if (!_exit.isCompleted) _exit.complete(-1);
    // The node finished and closed its side: end our output streams so consumers
    // (e.g. `execute`) observe completion. Already-buffered output is delivered
    // before the streams close.
    unawaited(_controlSub.cancel());
    unawaited(_channel.close());
  }

  /// Closes the session, asking the node to terminate the process.
  Future<void> close() async {
    _channel.sendControl(
      ChannelClose(channel: _channel.id, reason: 'client_closed'),
    );
    await _controlSub.cancel();
    if (!_exit.isCompleted) _exit.complete(-1);
    await _channel.close();
  }
}
