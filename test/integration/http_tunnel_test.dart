@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart' show HubBroker, PortRange;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Below every platform's ephemeral range, and disjoint from
/// `tunnel_test.dart`'s, so the two suites can run concurrently.
const _ports = PortRange(18600, 18700);

/// One request as the target HTTP server saw it.
typedef _Seen = ({String path, String body, HttpHeaders headers});

void main() {
  late TestCluster cluster;
  late HttpServer target;
  final seen = <_Seen>[];

  setUp(() async {
    seen.clear();
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((m) => ws.add('echo:$m'), onDone: ws.close);
        return;
      }
      final body = await utf8.decodeStream(req);
      seen.add((path: req.uri.path, body: body, headers: req.headers));
      req.response
        ..write('ok:${req.uri.path}:${body.length}')
        ..close();
    });
  });

  tearDown(() async {
    await target.close(force: true);
    await cluster.dispose();
  });

  Future<void> startCluster({bool secure = false}) async {
    cluster = await TestCluster.start(
      tunnelPortRange: _ports,
      tunnelSecurityContext: secure ? hubSecurityContext() : null,
    );
  }

  HttpClient httpClient() {
    final c = HttpClient(context: trustContext())
      ..badCertificateCallback = (_, _, _) => true;
    addTearDown(() => c.close(force: true));
    return c;
  }

  Future<String> send(
    HttpClient http,
    Uri url, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
  }) async {
    final req = await http.openUrl(method, url);
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.chunkedTransferEncoding = true;
      req.write(body);
    }
    final res = await req.close();
    return utf8.decodeStream(res).timeout(const Duration(seconds: 15));
  }

  test('an HTTP tunnel adds forwarding headers to every request', () async {
    await startCluster();
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
    );
    expect(t.protocol, TunnelProtocol.http);
    expect(t.scheme, 'http');
    expect(t.publicAddress('hub'), 'http://127.0.0.1:${t.publicPort}');

    final http = httpClient();
    final base = Uri.parse('http://127.0.0.1:${t.publicPort}');
    // Three requests on one keep-alive connection, one with a chunked body.
    expect(await send(http, base.resolve('/a')), 'ok:/a:0');
    expect(
      await send(http, base.resolve('/b'), method: 'POST', body: 'x' * 300000),
      'ok:/b:300000',
    );
    expect(await send(http, base.resolve('/c')), 'ok:/c:0');

    expect(seen.map((s) => s.path), ['/a', '/b', '/c']);
    expect(seen[1].body.length, 300000);
    final ids = <String>{};
    for (final s in seen) {
      final h = s.headers;
      expect(h.value('x-forwarded-for'), '127.0.0.1');
      expect(h.value('x-real-ip'), '127.0.0.1');
      expect(h.value('x-forwarded-proto'), 'http');
      expect(h.value('x-forwarded-ssl'), 'off');
      expect(h.value('x-forwarded-host'), '127.0.0.1:${t.publicPort}');
      expect(h.value('x-forwarded-port'), '${t.publicPort}');
      expect(
        h.value('forwarded'),
        'for=127.0.0.1;proto=http;host="127.0.0.1:${t.publicPort}"',
      );
      expect(h.value('via'), '1.1 ${HubBroker.tunnelViaName}');
      expect(h.value('x-omnyshell-tunnel-id'), t.shortId);
      expect(h.value('x-omnyshell-node'), 'web-01');
      expect(h.value('x-omnyshell-owner'), 'alice');
      ids.add(h.value('x-request-id')!);
    }
    expect(ids, hasLength(3), reason: 'each request gets its own id');

    final listed = (await client.listTunnels()).single;
    expect(listed.protocol, TunnelProtocol.http);
    expect(listed.scheme, 'http');
  });

  test('a secure HTTP tunnel reports https', () async {
    await startCluster(secure: true);
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      secure: true,
      protocol: TunnelProtocol.http,
    );
    expect(t.scheme, 'https');

    final url = Uri.parse('https://127.0.0.1:${t.publicPort}/s');
    expect(await send(httpClient(), url), 'ok:/s:0');
    final h = seen.single.headers;
    expect(h.value('x-forwarded-proto'), 'https');
    expect(h.value('x-forwarded-ssl'), 'on');
    expect(h.value('forwarded'), contains('proto=https'));
  });

  test('client-sent forwarding headers are kept and ours appended', () async {
    await startCluster();
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
    );

    await send(
      httpClient(),
      Uri.parse('http://127.0.0.1:${t.publicPort}/spoof'),
      headers: {
        'x-forwarded-for': '6.6.6.6',
        'x-forwarded-proto': 'https',
        'x-real-ip': '6.6.6.6',
        'x-request-id': 'mine',
        'x-omnyshell-node': 'evil',
      },
    );
    final h = seen.single.headers;
    expect(h.value('x-forwarded-for'), '6.6.6.6, 127.0.0.1');
    expect(h.value('x-forwarded-proto'), 'https, http');
    expect(h.value('x-omnyshell-node'), 'evil, web-01');
    // Single-valued headers keep the first hop's value.
    expect(h.value('x-real-ip'), '6.6.6.6');
    expect(h.value('x-request-id'), 'mine');
  });

  test('a WebSocket works through an HTTP tunnel', () async {
    await startCluster();
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
    );
    final ws = await WebSocket.connect('ws://127.0.0.1:${t.publicPort}/ws');
    addTearDown(ws.close);
    final replies = ws.take(2).toList();
    ws
      ..add('one')
      ..add('two');
    expect(await replies.timeout(const Duration(seconds: 15)), [
      'echo:one',
      'echo:two',
    ]);
  });

  test('an @local HTTP tunnel adds the headers too', () async {
    await startCluster();
    final client = await cluster.connectClient();
    final t = await client.openTunnel(
      targetPort: target.port,
      local: true,
      protocol: TunnelProtocol.http,
    );
    await send(httpClient(), Uri.parse('http://127.0.0.1:${t.publicPort}/l'));
    final h = seen.single.headers;
    expect(h.value('x-omnyshell-node'), '@local');
    expect(h.value('x-forwarded-for'), '127.0.0.1');
  });

  test('a plain TCP tunnel leaves HTTP untouched', () async {
    await startCluster();
    await cluster.startNode(id: 'web-01');
    final client = await cluster.connectClient();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
    );
    expect(t.protocol, TunnelProtocol.tcp);
    expect(t.scheme, isNull);
    expect(t.publicAddress('hub'), '127.0.0.1:${t.publicPort}');

    await send(httpClient(), Uri.parse('http://127.0.0.1:${t.publicPort}/p'));
    final h = seen.single.headers;
    expect(h.value('x-forwarded-for'), isNull);
    expect(h.value('via'), isNull);
    expect(h.value('x-omnyshell-tunnel-id'), isNull);
  });
}
