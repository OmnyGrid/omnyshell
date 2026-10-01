@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/src/application/hub/tunnel_registry.dart';
import 'package:omnyshell/src/domain/auth/principal.dart';
import 'package:omnyshell/src/domain/entities/tunnel_info.dart';
import 'package:omnyshell/src/domain/value_objects/principal_id.dart';
import 'package:test/test.dart';

void main() {
  late ServerSocket socket;
  late TunnelRegistry registry;

  setUp(() async {
    // One real (unused) listener shared by every registration; the registry
    // only stores it.
    socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    registry = TunnelRegistry();
  });

  tearDown(() => socket.close());

  TunnelRegistration reg(
    String id, {
    String owner = 'alice',
    String ownerConn = 'c1',
    String exposerConn = 'n1',
    int port = 9000,
  }) => TunnelRegistration(
    tunnelId: id,
    ownerConnId: ownerConn,
    exposerConnId: exposerConn,
    owner: Principal(id: PrincipalId(owner), displayName: owner),
    nodeId: 'node-a',
    targetHost: 'localhost',
    targetPort: 8080,
    publicHost: 'hub.example',
    publicPort: port,
    serverSocket: socket,
    createdAt: DateTime.utc(2026, 9, 26, 12),
  );

  group('TunnelRegistration', () {
    test('toInfo carries every wire field', () {
      final info = TunnelRegistration(
        tunnelId: 't-1',
        ownerConnId: 'c1',
        exposerConnId: 'c1',
        owner: Principal(id: PrincipalId('bob'), displayName: 'Bob'),
        nodeId: TunnelRegistration.localNode,
        targetHost: '10.0.0.5',
        targetPort: 5432,
        publicHost: 'hub.example',
        publicPort: 40001,
        serverSocket: socket,
        createdAt: DateTime.utc(2026, 1, 2),
        secure: true,
        protocol: TunnelProtocol.http,
      ).toInfo();

      expect(info.tunnelId, 't-1');
      expect(info.nodeId, '@local');
      expect(info.ownerUserId, 'bob');
      expect(info.targetHost, '10.0.0.5');
      expect(info.targetPort, 5432);
      expect(info.publicHost, 'hub.example');
      expect(info.publicPort, 40001);
      expect(info.secure, isTrue);
      expect(info.protocol, TunnelProtocol.http);
      expect(info.createdAt, DateTime.utc(2026, 1, 2));
    });

    test('is not secure by default', () {
      expect(reg('t').secure, isFalse);
      expect(reg('t').toInfo().secure, isFalse);
    });

    test('is plain TCP by default', () {
      expect(reg('t').protocol, TunnelProtocol.tcp);
      expect(reg('t').toInfo().protocol, TunnelProtocol.tcp);
    });
  });

  group('TunnelRegistry', () {
    test('add registers the tunnel and marks its port in use', () {
      registry.add(reg('t-1', port: 9001));

      expect(registry.byId('t-1')?.publicPort, 9001);
      expect(registry.isPortInUse(9001), isTrue);
      expect(registry.isPortInUse(9002), isFalse);
      expect(registry.all.map((r) => r.tunnelId), ['t-1']);
    });

    test('remove returns the tunnel and frees its port', () {
      registry.add(reg('t-1', port: 9001));

      final removed = registry.remove('t-1');

      expect(removed?.tunnelId, 't-1');
      expect(registry.byId('t-1'), isNull);
      expect(registry.isPortInUse(9001), isFalse);
      expect(registry.all, isEmpty);
    });

    test('removing an unknown tunnel is a null no-op', () {
      registry.add(reg('t-1', port: 9001));

      expect(registry.remove('nope'), isNull);
      expect(registry.isPortInUse(9001), isTrue);
    });

    test('ownedByPrincipal filters by owner, not connection', () {
      registry
        ..add(reg('a1', owner: 'alice', ownerConn: 'c1', port: 1))
        ..add(reg('a2', owner: 'alice', ownerConn: 'c9', port: 2))
        ..add(reg('b1', owner: 'bob', port: 3));

      expect(
        registry.ownedByPrincipal('alice').map((r) => r.tunnelId),
        unorderedEquals(['a1', 'a2']),
      );
      expect(registry.ownedByPrincipal('carol'), isEmpty);
    });

    test('exposedBy filters by the exposer connection', () {
      registry
        ..add(reg('x', exposerConn: 'node-conn', port: 1))
        ..add(reg('y', exposerConn: 'node-conn', port: 2))
        ..add(reg('z', exposerConn: 'other', port: 3));

      expect(
        registry.exposedBy('node-conn').map((r) => r.tunnelId),
        unorderedEquals(['x', 'y']),
      );
      expect(registry.exposedBy('gone'), isEmpty);
    });

    group('resolveOwned', () {
      setUp(() {
        registry
          ..add(reg('abc123', port: 1))
          ..add(reg('abd456', port: 2))
          ..add(reg('abc', port: 3))
          ..add(reg('zzz999', owner: 'bob', port: 4));
      });

      test('an exact id wins even when it prefixes another id', () {
        expect(registry.resolveOwned('alice', 'abc')?.tunnelId, 'abc');
      });

      test('an unambiguous prefix resolves', () {
        expect(registry.resolveOwned('alice', 'abd')?.tunnelId, 'abd456');
        expect(registry.resolveOwned('alice', 'abc1')?.tunnelId, 'abc123');
      });

      test('an ambiguous prefix resolves to null', () {
        expect(registry.resolveOwned('alice', 'ab'), isNull);
      });

      test("another principal's tunnel is never resolved", () {
        expect(registry.resolveOwned('alice', 'zzz999'), isNull);
        expect(registry.resolveOwned('alice', 'zz'), isNull);
        expect(registry.resolveOwned('bob', 'zz')?.tunnelId, 'zzz999');
      });

      test('no match resolves to null', () {
        expect(registry.resolveOwned('alice', 'q'), isNull);
      });
    });
  });
}
