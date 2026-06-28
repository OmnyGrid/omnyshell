import '../../protocol/channel.dart';

/// Bridges a Hub-forwarded `@local` tunnel connection to a target the client's
/// own machine can reach. Native builds dial a real TCP socket; the browser
/// cannot, so its implementation is an inert stub.
abstract class LocalTunnelBridge {
  /// Dials the target and starts piping. Returns `true` on success, or `false`
  /// (without starting) when the target is unreachable or the platform cannot
  /// open local sockets (the browser).
  Future<bool> connect();

  /// Tears the bridge down (used on disconnect / exposer shutdown).
  Future<void> close();
}

/// Constructs a [LocalTunnelBridge] for an adopted tunnel [channel].
typedef LocalTunnelBridgeFactory =
    LocalTunnelBridge Function({
      required Channel channel,
      required String targetHost,
      required int targetPort,
      required Future<void> Function() onClose,
    });
