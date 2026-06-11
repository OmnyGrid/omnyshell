@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart' show PortRange;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Starts an in-process TCP echo server on a free loopback port.
Future<ServerSocket> _startEcho() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    socket.listen(
      socket.add,
      onDone: () => socket.destroy(),
      onError: (Object _) => socket.destroy(),
    );
  });
  return server;
}

/// Connects to [port], sends [payload], and returns the bytes echoed back once
/// at least [payload].length bytes have arrived. Reads concurrently with the
/// write so a large payload does not deadlock the echo loop.
Future<Uint8List> _echoRoundTrip(int port, Uint8List payload) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final out = BytesBuilder(copy: false);
  final got = Completer<Uint8List>();
  final sub = socket.listen(
    (d) {
      out.add(d);
      if (out.length >= payload.length && !got.isCompleted) {
        got.complete(out.toBytes());
      }
    },
    onDone: () {
      if (!got.isCompleted) got.complete(out.toBytes());
    },
    onError: (Object e) {
      if (!got.isCompleted) got.completeError(e);
    },
  );
  socket.add(payload);
  await socket.flush();
  try {
    return await got.future.timeout(const Duration(seconds: 15));
  } finally {
    await sub.cancel();
    socket.destroy();
  }
}

void main() {
  late TestCluster cluster;
  late ServerSocket echo;

  tearDown(() async {
    await echo.close();
    await cluster.dispose();
  });

  Future<void> startCluster({
    PortRange? range = const PortRange(34000, 34100),
  }) async {
    cluster = await TestCluster.start(tunnelPortRange: range);
    echo = await _startEcho();
  }

  test(
    'exposes a node port and round-trips bytes through the public port',
    () async {
      await startCluster();
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();

      final tunnel = await client.openTunnel(
        nodeId: 'web-01',
        targetPort: echo.port,
      );
      expect(tunnel.publicPort, inInclusiveRange(34000, 34100));
      expect(tunnel.nodeId, 'web-01');

      final reply = await _echoRoundTrip(
        tunnel.publicPort,
        Uint8List.fromList('ping'.codeUnits),
      );
      expect(String.fromCharCodes(reply), 'ping');
    },
  );

  test('streams a payload larger than the flow-control window', () async {
    await startCluster();
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final tunnel = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: echo.port,
    );

    // > 4 * the 256 KiB per-stream window, to exercise credit + backpressure.
    final payload = Uint8List(2 * 1024 * 1024);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = i & 0xFF;
    }
    final reply = await _echoRoundTrip(tunnel.publicPort, payload);
    expect(reply.length, payload.length);
    expect(reply, orderedEquals(payload));
  });

  test(
    'honours a specific in-range public port and rejects out-of-range',
    () async {
      await startCluster();
      await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();

      final tunnel = await client.openTunnel(
        nodeId: 'web-01',
        targetPort: echo.port,
        publicPort: 34050,
      );
      expect(tunnel.publicPort, 34050);

      await expectLater(
        client.openTunnel(
          nodeId: 'web-01',
          targetPort: echo.port,
          publicPort: 50000,
        ),
        throwsA(
          isA<TunnelRejectedException>().having(
            (e) => e.code,
            'code',
            'port_out_of_range',
          ),
        ),
      );
    },
  );

  test('fails closed when the hub has no tunnel range configured', () async {
    await startCluster(range: null);
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();

    await expectLater(
      client.openTunnel(nodeId: 'web-01', targetPort: echo.port),
      throwsA(
        isA<TunnelRejectedException>().having(
          (e) => e.code,
          'code',
          'tunnel_disabled',
        ),
      ),
    );
  });

  test('rejects an unauthorized principal', () async {
    await startCluster();
    // Default node labels are admin-only; a developer is not authorized.
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient(
      token: 'dev-token',
      principal: 'dev',
    );

    await expectLater(
      client.openTunnel(nodeId: 'web-01', targetPort: echo.port),
      throwsA(
        isA<TunnelRejectedException>().having(
          (e) => e.code,
          'code',
          'not_authorized',
        ),
      ),
    );
  });

  test('closing a tunnel stops accepting public connections', () async {
    await startCluster();
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final tunnel = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: echo.port,
    );

    // Works before close.
    final reply = await _echoRoundTrip(
      tunnel.publicPort,
      Uint8List.fromList('hi'.codeUnits),
    );
    expect(String.fromCharCodes(reply), 'hi');

    final result = await client.closeTunnel(tunnel.tunnelId);
    expect(result.ok, isTrue);
    expect(await client.listTunnels(), isEmpty);

    // The public listener is gone; a fresh connection is refused.
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, tunnel.publicPort),
      throwsA(isA<SocketException>()),
    );
  });

  test(
    'a node-exposed tunnel is torn down when the node disconnects',
    () async {
      await startCluster();
      final node = await cluster.startNode(id: 'web-01');
      final client = await cluster.connectClient();
      final tunnel = await client.openTunnel(
        nodeId: 'web-01',
        targetPort: echo.port,
      );

      await node.shutdown();
      // Give the hub a moment to observe the disconnect and close the listener.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, tunnel.publicPort),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test('exposes the local machine via @local and round-trips bytes', () async {
    await startCluster();
    final client = await cluster.connectClient();

    final tunnel = await client.openTunnel(targetPort: echo.port, local: true);
    expect(tunnel.nodeId, '@local');
    expect(tunnel.publicPort, inInclusiveRange(34000, 34100));

    final reply = await _echoRoundTrip(
      tunnel.publicPort,
      Uint8List.fromList('local'.codeUnits),
    );
    expect(String.fromCharCodes(reply), 'local');
  });
}
