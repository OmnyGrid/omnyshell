@TestOn('vm')
library;

import 'dart:async';

import 'package:omnyshell/omnyshell_hub.dart';
import 'package:test/test.dart';

import '../../support/loopback_connection.dart';

/// A newer client can ask for a tunnel protocol this Hub does not know. That
/// never survives the wire codec today (an unknown name decodes to `null`), so
/// drive the broker over an in-memory connection — frames pass by reference —
/// to prove the Hub refuses it instead of silently opening plain TCP.
void main() {
  test('the Hub rejects an unknown tunnel protocol', () async {
    final broker = HubBroker(
      authenticator: TokenAuthenticator({
        'admin-token': TokenGrant(
          principal: PrincipalId('alice'),
          roles: {'admin'},
        ),
      }),
      authorizer: const RoleBasedAuthorizer(),
      tunnelPortRange: const PortRange(18750, 18760),
      tunnelBindHost: '127.0.0.1',
    );
    final conn = LoopbackConnection();
    addTearDown(conn.close);
    broker.accept(conn);

    Future<T> reply<T extends ControlMessage>() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        for (final f in conn.sent) {
          if (f is ControlFrame && f.message is T) return f.message as T;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      throw TimeoutException('no $T from the Hub');
    }

    conn
      ..deliver(
        const ControlFrame(
          Hello(
            role: 'client',
            protocolVersion: kProtocolVersion,
            minVersion: kMinProtocolVersion,
          ),
        ),
      )
      ..deliver(
        const ControlFrame(
          AuthRequest(
            method: 'token',
            principal: 'alice',
            token: 'admin-token',
          ),
        ),
      );
    await reply<AuthOk>();

    conn.deliver(
      const ControlFrame(
        TunnelOpenRequest(
          requestId: 'r1',
          nodeId: TunnelOpenRequest.localNode,
          targetPort: 8080,
          protocol: null,
        ),
      ),
    );
    final rejected = await reply<TunnelRejected>();
    expect(rejected.requestId, 'r1');
    expect(rejected.reason, 'unsupported_protocol');
    expect(rejected.message, contains('tcp, http'));
    expect(
      conn.sent.whereType<ControlFrame>().map((f) => f.message),
      isNot(contains(isA<TunnelOpened>())),
    );
  });
}
