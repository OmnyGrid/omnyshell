@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/src/infrastructure/transport/ws_channel_connection.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

/// A loopback WebSocket server whose single accepted peer the test drives: it
/// records what the client sends in [received] and can push events or close.
class _Peer {
  _Peer._(this._server);

  final HttpServer _server;
  final _socket = Completer<WebSocket>();
  final List<Object?> received = [];
  final _closed = Completer<void>();

  static Future<_Peer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final peer = _Peer._(server);
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen(
        peer.received.add,
        onDone: () {
          if (!peer._closed.isCompleted) peer._closed.complete();
        },
      );
      peer._socket.complete(ws);
    });
    return peer;
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}');

  Future<WebSocket> get socket => _socket.future;

  /// Completes when the client side closes the socket.
  Future<void> get closedByClient => _closed.future;

  Future<void> stop() => _server.close(force: true);
}

const _hello = Hello(
  role: 'node',
  protocolVersion: 1,
  minVersion: 1,
  nonce: 'n-1',
);

void main() {
  late _Peer peer;
  late WsChannelConnection conn;

  setUp(() async {
    peer = await _Peer.start();
    final channel = IOWebSocketChannel.connect(peer.uri);
    await channel.ready;
    conn = WsChannelConnection.fromChannel(channel);
    await peer.socket;
  });

  tearDown(() async {
    await conn.close();
    await peer.stop();
  });

  test('uses the standard codec unless one is given', () {
    expect(conn.codec.registeredTypes, contains('hello'));
    expect(conn.isOpen, isTrue);
  });

  test('sends a control frame as JSON text', () async {
    conn.send(const ControlFrame(_hello));
    await _until(() => peer.received.isNotEmpty);

    final text = peer.received.single as String;
    expect(jsonDecode(text)['t'], 'hello');
  });

  test('sends a data frame as binary', () async {
    conn.send(
      DataFrame(
        opcode: DataOpcode.stdin,
        channel: 2,
        payload: Uint8List.fromList([4, 5, 6]),
      ),
    );
    await _until(() => peer.received.isNotEmpty);

    final decoded = FrameCodec.standard().decode(peer.received.single!);
    expect(decoded, isA<DataFrame>());
    expect((decoded as DataFrame).channel, 2);
    expect(decoded.payload, [4, 5, 6]);
  });

  test('decodes inbound frames and drops undecodable ones', () async {
    final frames = <OmnyShellFrame>[];
    conn.incoming.listen(frames.add);
    final ws = await peer.socket;

    ws.add('not json {{{'); // dropped, connection stays up
    ws.add(FrameCodec.standard().encodeControl(_hello));
    ws.add(
      FrameCodec.standard().encode(
        DataFrame(
          opcode: DataOpcode.stdout,
          channel: 7,
          payload: Uint8List.fromList([1]),
        ),
      ),
    );
    await _until(() => frames.length == 2);

    expect(((frames[0] as ControlFrame).message as Hello).nonce, 'n-1');
    expect((frames[1] as DataFrame).channel, 7);
    expect(conn.isOpen, isTrue);
  });

  test('close closes the socket, completes done and ends incoming', () async {
    final incomingDone = conn.incoming.toList();

    await conn.close(1000, 'bye');

    expect(conn.isOpen, isFalse);
    await conn.done;
    expect(await incomingDone, isEmpty);
    await peer.closedByClient;
    expect((await peer.socket).closeCode, 1000);

    // Sending or closing again after close is a harmless no-op.
    conn.send(const ControlFrame(_hello));
    await conn.close();
    expect(peer.received, isEmpty);
  });

  test('a peer-initiated close completes done and ends incoming', () async {
    final incomingDone = conn.incoming.toList();

    await (await peer.socket).close();

    await conn.done;
    expect(await incomingDone, isEmpty);
    expect(conn.isOpen, isFalse);
  });
}

/// Pumps the event loop until [condition] holds (bounded, so a bug fails fast
/// instead of hanging).
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}
