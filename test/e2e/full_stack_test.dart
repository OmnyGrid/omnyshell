@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

void main() {
  late TestCluster cluster;

  setUp(() async => cluster = await TestCluster.start());
  tearDown(() async => cluster.dispose());

  test(
    'Client → Hub → Node: exec a real command end-to-end over wss',
    () async {
      await cluster.startNode(
        id: 'worker-01',
        labels: {'allow-roles': 'admin'},
      );
      final client = await cluster.connectClient();

      final result = await client.execute(
        nodeId: 'worker-01',
        command: 'echo omnyshell-e2e',
      );
      expect(result.exitCode, 0);
      expect(result.stdoutText.trim(), 'omnyshell-e2e');
    },
  );

  test(
    'streams output larger than the channel send window without stalling',
    () async {
      await cluster.startNode(
        id: 'worker-01',
        labels: {'allow-roles': 'admin'},
      );
      final client = await cluster.connectClient();

      // 100k lines of "omnyshell\n" ≈ 1 MB, far past the 256 KiB credit window.
      // Without the client replenishing the send window as it consumes output,
      // the node's credit drains and the stream stalls — the timeout then fails
      // the test instead of hanging it.
      final result = await client
          .execute(
            nodeId: 'worker-01',
            command: 'yes omnyshell | head -n 100000',
          )
          .timeout(const Duration(seconds: 30));

      expect(result.exitCode, 0);
      expect(const LineSplitter().convert(result.stdoutText).length, 100000);
    },
  );

  test('exit codes from real processes propagate to the client', () async {
    await cluster.startNode(id: 'worker-01', labels: {'allow-roles': 'admin'});
    final client = await cluster.connectClient();

    final result = await client.execute(nodeId: 'worker-01', command: 'exit 5');
    expect(result.exitCode, 5);
  });

  test('discovery lists the registered node', () async {
    await cluster.startNode(id: 'worker-01');
    final client = await cluster.connectClient();

    final nodes = await client.listNodes();
    expect(nodes.map((n) => n.id.value), contains('worker-01'));
    expect(nodes.firstWhere((n) => n.id.value == 'worker-01').online, isTrue);
  });

  test(
    'a node leaves serving and retries when the Hub goes away',
    () async {
      final node = await cluster.startNode(id: 'resilient-01');
      expect(node.state, NodeState.serving);

      await cluster.hub.stop();

      // Poll until the node notices the dropped connection and starts retrying.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (node.state == NodeState.serving &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        node.state,
        anyOf(
          NodeState.backoff,
          NodeState.connecting,
          NodeState.authenticating,
        ),
      );
      expect(node.state, isNot(NodeState.stopped));
    },
    skip: Platform.isWindows ? 'signal handling differs' : null,
  );
}
