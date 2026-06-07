@TestOn('vm')
library;

import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

void main() {
  late TestCluster cluster;

  setUp(() async => cluster = await TestCluster.start());
  tearDown(() async => cluster.dispose());

  test('a node registers and becomes discoverable', () async {
    await cluster.startNode(id: 'web-01', labels: {'env': 'prod'});

    final node = cluster.hub.nodes.byId(NodeId('web-01'));
    expect(node, isNotNull);
    expect(node!.descriptor.online, isTrue);
    expect(node.descriptor.labels['env'], 'prod');
    expect(node.descriptor.platform.os, isNotEmpty);
  });

  test(
    'the hub acknowledges heartbeats and records sequence numbers',
    () async {
      final node = cluster.hub.nodes;
      await cluster.startNode(id: 'beat-01');

      // The node heartbeats every 200ms in the harness; wait for at least one.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final registered = node.byId(NodeId('beat-01'))!;
      expect(registered.lastHeartbeatSeq, greaterThanOrEqualTo(1));
    },
  );

  test('discovery filters by label', () async {
    await cluster.startNode(id: 'prod-01', labels: {'env': 'prod'});
    await cluster.startNode(id: 'stg-01', labels: {'env': 'staging'});

    final prod = cluster.hub.nodes.list(filter: {'env': 'prod'});
    expect(prod.map((n) => n.id.value), ['prod-01']);
  });

  test('a disconnected node is removed from the registry', () async {
    final node = await cluster.startNode(id: 'gone-01');
    await node.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cluster.hub.nodes.byId(NodeId('gone-01')), isNull);
  });
}
