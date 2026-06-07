import 'dart:async';

import '../../shared/utils/clock.dart';
import 'node_registry.dart';

/// Watches node liveness and reports nodes that have stopped heartbeating.
///
/// On each [tick] (driven by a periodic timer in production, or called directly
/// in tests), any node whose last-seen time is older than [timeout] is passed
/// to [onTimeout] for teardown. All timing is [Clock]-driven so tests stay
/// deterministic.
class HeartbeatMonitor {
  /// The registry to scan.
  final NodeRegistry registry;

  /// The clock providing "now".
  final Clock clock;

  /// How long a node may go silent before being declared offline.
  final Duration timeout;

  /// Invoked for each node that has timed out.
  final void Function(RegisteredNode node) onTimeout;

  Timer? _timer;

  /// Creates a heartbeat monitor.
  HeartbeatMonitor({
    required this.registry,
    required this.onTimeout,
    this.clock = const SystemClock(),
    this.timeout = const Duration(seconds: 30),
  });

  /// Starts periodic checking every [interval] (default: a third of [timeout]).
  void start({Duration? interval}) {
    stop();
    final period =
        interval ??
        Duration(
          milliseconds: (timeout.inMilliseconds ~/ 3).clamp(1000, 60000),
        );
    _timer = Timer.periodic(period, (_) => tick());
  }

  /// Stops periodic checking.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Scans the registry once, reporting any timed-out nodes.
  void tick() {
    final now = clock.now();
    final expired = <RegisteredNode>[];
    for (final node in registry.all) {
      if (now.difference(node.lastSeen) > timeout) {
        expired.add(node);
      }
    }
    for (final node in expired) {
      onTimeout(node);
    }
  }
}
