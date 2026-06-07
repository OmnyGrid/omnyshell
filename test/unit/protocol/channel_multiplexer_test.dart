import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

import '../../support/loopback_connection.dart';

void main() {
  late LoopbackConnection conn;
  late ChannelMultiplexer mux;

  setUp(() {
    conn = LoopbackConnection();
    mux = ChannelMultiplexer(conn);
  });

  tearDown(() async {
    await mux.dispose();
    await conn.close();
  });

  test('open() allocates increasing channel ids', () {
    expect(mux.open().id, 1);
    expect(mux.open().id, 2);
  });

  test('routes inbound data frames to the matching channel', () async {
    final channel = mux.adopt(5);
    final received = <int>[];
    channel.stdout.listen(received.addAll);

    conn.deliver(
      DataFrame(
        opcode: DataOpcode.stdout,
        channel: 5,
        payload: Uint8List.fromList([10, 20, 30]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(received, [10, 20, 30]);
  });

  test('routes channel-scoped control to the channel', () async {
    final channel = mux.adopt(8);
    final control = <ControlMessage>[];
    channel.control.listen(control.add);

    conn.deliver(
      ControlFrame(
        ChannelExit(channel: 8, exitCode: 3, ts: DateTime.utc(2026)),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(control.single, isA<ChannelExit>());
    expect((control.single as ChannelExit).exitCode, 3);
  });

  test('surfaces unrouted control on the control stream', () async {
    final seen = <ControlMessage>[];
    mux.control.listen(seen.add);

    conn.deliver(ControlFrame(Ping(id: 'p', ts: DateTime.utc(2026))));
    await Future<void>.delayed(Duration.zero);
    expect(seen.single, isA<Ping>());
  });

  test('window message replenishes a channel send credit', () async {
    final channel = mux.adopt(3);
    // Exhaust the window with a large write, then verify queueing.
    final big = Uint8List(Channel.defaultWindow + 100);
    channel.sendStdout(big);
    expect(channel.queuedBytes, greaterThan(0));

    conn.deliver(
      ControlFrame(ChannelWindow(channel: 3, stream: 'stdout', credit: 1000)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(channel.queuedBytes, lessThan(big.length));
  });

  test('channel splits writes into protocol-sized data frames', () {
    final channel = mux.adopt(2);
    final payload = Uint8List(70 * 1024); // > 64 KiB
    channel.sendStdin(payload);
    final dataFrames = conn.sent.whereType<DataFrame>().toList();
    expect(dataFrames.length, 2);
    expect(dataFrames.every((f) => f.payload.length <= 64 * 1024), isTrue);
  });

  test('encodes UTF-8 stdin payloads end-to-end', () async {
    final channel = mux.adopt(9);
    channel.sendStdin(utf8.encode('hi'));
    final frame = conn.sent.whereType<DataFrame>().single;
    expect(frame.opcode, DataOpcode.stdin);
    expect(utf8.decode(frame.payload), 'hi');
  });
}
