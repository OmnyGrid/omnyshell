import 'dart:async';

import 'package:omnyhub/omnyhub.dart' as omnyhub;

import '../../infrastructure/transport/frame_connection.dart';
import '../../protocol/frame_codec.dart';
import 'hub_broker.dart';

/// The OmnyShell Hub as an omnyhub [omnyhub.Service], so its broker can be
/// hosted on any [omnyhub.OmnyHub] listener instead of owning one.
///
/// This is what lets a *different* Hub — an OmnyServer Hub, say — also serve
/// OmnyShell nodes: mount this at a path and OmnyShell traffic is routed to it
/// while the host keeps its own surfaces on the same port and certificate.
///
/// ```dart
/// // On an OmnyServer (or any omnyhub) Hub:
/// await hub.registerService(OmnyShellHubService(broker, mount: '/shell'));
/// // Nodes then dial wss://host:8443/shell
/// ```
///
/// [HubBroker] is transport-agnostic — it is driven by `accept`ing connections —
/// so this class is only an adapter: omnyhub hands over a raw
/// [omnyhub.Connection], and [FrameConnection] wraps it in OmnyShell's frame
/// codec.
///
/// **The broker must own the socket un-intercepted.** OmnyShell authenticates
/// *in band*, after the upgrade: the Hub speaks first with a challenge `hello`,
/// and the peer answers with an `auth.request`. So this route must not be given
/// an [omnyhub.ConnectionAuthenticator] — one would consume the very frames the
/// broker is waiting for. Note that on omnyhub a route's `null` authenticator
/// means *inherit the hub-wide one*, not *none*: a host hub that sets a hub-wide
/// connection authenticator must ensure it does not reach this mount.
class OmnyShellHubService extends omnyhub.ServiceBase {
  /// The broker that authenticates, authorizes and relays.
  final HubBroker broker;

  /// Builds the frame codec for each accepted connection.
  final FrameCodec Function()? codecFactory;

  /// Whether this service owns [broker]'s lifecycle.
  ///
  /// `true` (the default) starts and stops the broker with the hosting hub. Set
  /// it `false` when the embedder already drives the broker — as `OmnyShellHub`
  /// does — so it is not started twice.
  final bool ownsBroker;

  /// Mounts [broker] as a service.
  ///
  /// The default mount is `/`, which matches every path — the behaviour of a
  /// standalone OmnyShell Hub, whose listener upgrades a WebSocket regardless of
  /// path. Give it a specific mount (e.g. `/shell`) when sharing a listener.
  OmnyShellHubService(
    this.broker, {
    super.name = 'omnyshell',
    super.mount = '/',
    this.codecFactory,
    this.ownsBroker = true,
  });

  @override
  void handleConnection(
    omnyhub.Connection connection,
    omnyhub.HubRequest request,
  ) => broker.accept(
    FrameConnection.wrap(connection, codec: codecFactory?.call()),
  );

  /// A plain HTTP request on the mount: this is a WebSocket endpoint, so answer
  /// with a small status document rather than an upgrade.
  @override
  Future<omnyhub.HubResponse> handle(omnyhub.HubRequest request) async =>
      omnyhub.HubResponse.json({
        'service': 'omnyshell',
        'protocol': 'websocket',
        'hubUid': broker.hubUid,
        'nodes': broker.registry.all.length,
      });

  @override
  Future<void> start() async {
    if (ownsBroker) broker.start();
  }

  @override
  Future<void> stop() async {
    if (ownsBroker) broker.stop();
  }
}
