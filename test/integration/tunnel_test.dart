@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart' show PortRange;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Connects to [port] over TLS, sends [payload], and returns the echoed bytes.
/// Trusts the test certificate and ignores the loopback hostname mismatch.
Future<Uint8List> _secureEchoRoundTrip(int port, Uint8List payload) async {
  final socket = await SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    port,
    context: trustContext(),
    onBadCertificate: (_) => true,
  );
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

/// Polls until a fresh connection to [port] is refused, failing if it still
/// accepts after [timeout].
///
/// A tunnel's public listener is torn down *asynchronously* after `closeTunnel`
/// returns (or after a node disconnects), so a connection attempt made
/// immediately can still land on the not-yet-closed listener — the source of a
/// flaky `throwsA(SocketException)`. Retry until the listener is actually gone.
Future<void> _expectEventuallyRefused(
  int port, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      // Still accepting — the listener hasn't torn down yet. Close and retry.
      socket.destroy();
      if (DateTime.now().isAfter(deadline)) {
        fail('port $port still accepts connections after $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } on SocketException {
      return; // Refused: the public listener is gone, as expected.
    }
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
    bool secure = false,
  }) async {
    cluster = await TestCluster.start(
      tunnelPortRange: range,
      tunnelSecurityContext: secure ? hubSecurityContext() : null,
    );
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

  test('terminates TLS on a secure tunnel and round-trips bytes', () async {
    await startCluster(secure: true);
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();

    final tunnel = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: echo.port,
      secure: true,
    );
    expect(tunnel.secure, isTrue);
    expect(tunnel.publicPort, inInclusiveRange(34000, 34100));

    // A TLS client round-trips through to the plaintext target.
    final reply = await _secureEchoRoundTrip(
      tunnel.publicPort,
      Uint8List.fromList('secure'.codeUnits),
    );
    expect(String.fromCharCodes(reply), 'secure');

    // A plaintext client fails the TLS handshake instead of being bridged.
    final plain = await Socket.connect(
      InternetAddress.loopbackIPv4,
      tunnel.publicPort,
    );
    plain.add(Uint8List.fromList('plain'.codeUnits));
    await plain.flush();
    final closed = Completer<void>();
    plain.listen(
      (_) {},
      onDone: closed.complete,
      onError: (Object _) => closed.complete(),
      cancelOnError: true,
    );
    await expectLater(
      closed.future.timeout(const Duration(seconds: 5)),
      completes,
    );
    plain.destroy();
  });

  test('rejects a secure tunnel when the hub has no certificate', () async {
    await startCluster();
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();

    await expectLater(
      client.openTunnel(nodeId: 'web-01', targetPort: echo.port, secure: true),
      throwsA(
        isA<TunnelRejectedException>().having(
          (e) => e.code,
          'code',
          'secure_unavailable',
        ),
      ),
    );
  });

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

    // The public listener is gone; a fresh connection is refused (the teardown
    // is async, so poll until it actually stops accepting).
    await _expectEventuallyRefused(tunnel.publicPort);
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

      // The hub observes the disconnect and closes the listener asynchronously;
      // poll until the public port stops accepting.
      await _expectEventuallyRefused(tunnel.publicPort);
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
