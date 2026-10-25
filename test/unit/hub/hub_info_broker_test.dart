@TestOn('vm')
library;

import 'dart:async';

import 'package:omnyshell/omnyshell_hub.dart';
import 'package:test/test.dart';

import '../../support/harness.dart' show FixedClock;
import '../../support/loopback_connection.dart';

/// Drives the broker over an in-memory connection to pin down what only the
/// Hub side decides: who may ask for its description, and what clock its
/// uptime runs on.
void main() {
  late FixedClock clock;
  late HubBroker broker;
  late LoopbackConnection conn;

  setUp(() {
    clock = FixedClock(DateTime.utc(2026, 10, 25, 6));
    broker = HubBroker(
      authenticator: TokenAuthenticator({
        'admin-token': TokenGrant(
          principal: PrincipalId('alice'),
          roles: {'admin'},
        ),
      }),
      authorizer: const RoleBasedAuthorizer(),
      clock: clock,
    );
    conn = LoopbackConnection();
    broker.accept(conn);
  });

  tearDown(() async {
    broker.stop();
    await conn.close();
  });

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

  void hello() => conn.deliver(
    const ControlFrame(
      Hello(
        role: 'client',
        protocolVersion: kProtocolVersion,
        minVersion: kMinProtocolVersion,
      ),
    ),
  );

  Future<AuthOk> login() async {
    hello();
    conn.deliver(
      const ControlFrame(
        AuthRequest(method: 'token', principal: 'alice', token: 'admin-token'),
      ),
    );
    return reply<AuthOk>();
  }

  test('the login reply names the Hub version', () async {
    expect((await login()).hubVersion, omnyShellVersion);
  });

  test('an unauthenticated peer is refused, not described', () async {
    hello();
    conn.deliver(const ControlFrame(HubInfoRequest(requestId: 'r1')));

    final error = await reply<ProtocolError>();
    expect(error.code, ErrorCodes.notAuthenticated);
    expect(error.fatal, isTrue);
    expect(
      conn.sent.whereType<ControlFrame>().map((f) => f.message),
      isNot(contains(isA<HubInfoResponse>())),
    );
  });

  test('uptime runs on the Hub clock from when the broker started', () async {
    await login();
    clock.advance(const Duration(hours: 26, minutes: 5));
    conn.deliver(const ControlFrame(HubInfoRequest(requestId: 'r1')));

    final response = await reply<HubInfoResponse>();
    expect(response.requestId, 'r1');
    expect(response.info.startedAt, DateTime.utc(2026, 10, 25, 6));
    expect(response.info.uptime, const Duration(hours: 26, minutes: 5));
    expect(response.info.clients, 1);
    expect(response.info.tunnelPorts, isNull); // no tunnel range configured
    expect(response.info.aiProvider, isNull); // no AI proxy configured
  });
}
