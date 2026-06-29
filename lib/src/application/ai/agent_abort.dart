import 'dart:async';

/// A cooperative cancellation signal for an [AgentService] run.
///
/// The host requests an abort (e.g. on Ctrl-C, or an `abort` answer at a
/// prompt); the agent loop notices at its next checkpoint and stops. A bare
/// [request] is *unconfirmed* — the loop asks the user "Abort? [y/N]" first;
/// [confirm] marks it as already confirmed (an explicit `abort` answer), so the
/// loop stops without re-asking. [clear] resets a request the user declined.
///
/// Pure Dart (no `dart:io`), so it works in the CLI and the browser.
class AgentAbort {
  bool _requested = false;
  bool _confirmed = false;
  Completer<void> _signal = Completer<void>();

  /// Whether an abort has been requested (confirmed or not).
  bool get isRequested => _requested;

  /// Whether the abort is confirmed and the loop should stop without asking.
  bool get isConfirmed => _confirmed;

  /// Completes the next time [request] is called — used to race against a
  /// pending model call so an abort is responsive. A fresh future is installed
  /// by [clear] after a declined request.
  Future<void> get whenRequested => _signal.future;

  /// Requests an abort (idempotent). Wakes any [whenRequested] waiter.
  void request() {
    if (_requested) return;
    _requested = true;
    if (!_signal.isCompleted) _signal.complete();
  }

  /// Requests an abort that needs no further confirmation (explicit intent).
  void requestConfirmed() {
    _confirmed = true;
    request();
  }

  /// Marks a pending request as confirmed.
  void confirm() => _confirmed = true;

  /// Clears a request the user declined, re-arming [whenRequested].
  void clear() {
    _requested = false;
    _signal = Completer<void>();
  }
}
