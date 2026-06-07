import 'dart:math';

/// Computes reconnect delays with exponential backoff and jitter.
///
/// The node uses this to space out reconnection attempts after the Hub
/// connection drops: the delay starts at [initial], multiplies by [factor] each
/// attempt up to [maxDelay], and is perturbed by up to [jitter] fraction to
/// avoid thundering herds. A successful, durable connection should call [reset].
class ReconnectPolicy {
  /// The delay before the first reconnect attempt.
  final Duration initial;

  /// The cap on the delay.
  final Duration maxDelay;

  /// The multiplier applied each attempt.
  final double factor;

  /// The maximum random jitter as a fraction of the computed delay (0–1).
  final double jitter;

  final Random _random;
  int _attempt = 0;

  /// Creates a reconnect policy.
  ReconnectPolicy({
    this.initial = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.factor = 2.0,
    this.jitter = 0.2,
    Random? random,
  }) : _random = random ?? Random();

  /// The number of attempts since the last [reset].
  int get attempt => _attempt;

  /// Returns the next backoff delay and advances the attempt counter.
  Duration nextDelay() {
    final base = initial.inMilliseconds * pow(factor, _attempt);
    final capped = base.clamp(
      initial.inMilliseconds.toDouble(),
      maxDelay.inMilliseconds.toDouble(),
    );
    final jitterMs = capped * jitter * _random.nextDouble();
    _attempt++;
    return Duration(milliseconds: (capped + jitterMs).round());
  }

  /// Resets the backoff after a healthy connection.
  void reset() => _attempt = 0;
}
