@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart' show PortRange;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Disjoint from the other tunnel suites' ranges so they can run concurrently.
const _ports = PortRange(18800, 18900);

const _mib = 1024 * 1024;

void main() {
  late TestCluster cluster;
  late HttpServer target;
  final hits = <String, int>{};

  setUp(() async {
    hits.clear();
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((req) async {
      final path = req.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      await req.drain<void>();
      final res = req.response;
      switch (path) {
        case '/hang':
          return; // never answers
        case '/close':
          // Drop the connection without any response.
          (await res.detachSocket(writeHeaders: false)).destroy();
          return;
        case '/static':
          res.headers
            ..set('cache-control', 'public, max-age=60')
            ..set('etag', '"v1"');
          res.write('static body');
        case '/private':
          res.headers.set('cache-control', 'private, max-age=60');
          res.write('private body');
        case '/cookie':
          res.headers
            ..set('cache-control', 'max-age=60')
            ..set('set-cookie', 'session=abc');
          res.write('cookie body');
        case '/nocc':
          res.write('no cache-control');
        default:
          res.write('dynamic ${hits[path]}');
      }
      await res.close();
    });
  });

  tearDown(() async {
    await target.close(force: true);
    await cluster.dispose();
  });

  Future<ClientRuntime> start({
    int perTunnel = 32 * _mib,
    int total = 128 * _mib,
  }) async {
    cluster = await TestCluster.start(
      tunnelPortRange: _ports,
      tunnelCacheMaxPerTunnel: perTunnel,
      tunnelCacheMaxTotal: total,
    );
    await cluster.startNode(id: 'web-01');
    return cluster.connectClient();
  }

  HttpClient httpClient() {
    final c = HttpClient();
    addTearDown(() => c.close(force: true));
    return c;
  }

  Future<(int, String, HttpHeaders)> get(
    TunnelHandle t,
    String path, {
    HttpClient? client,
    Map<String, String> headers = const {},
  }) async {
    final c = client ?? httpClient();
    final req = await c.get('127.0.0.1', t.publicPort, path);
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await utf8
        .decodeStream(res)
        .timeout(const Duration(seconds: 15));
    return (res.statusCode, body, res.headers);
  }

  test('a cached HTTP tunnel serves repeats from the Hub', () async {
    final client = await start();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
      cache: const TunnelCacheOptions(),
    );
    expect(t.cache, isNotNull);
    expect(t.cache!.maxBytes, 32 * _mib, reason: "the Hub's default");
    expect(t.cache!.maxEntryBytes, 8 * _mib);
    expect(t.timeouts!.isDefault, isTrue);

    final first = await get(t, '/static');
    expect(first.$3.value('x-cache'), 'MISS');
    // Separate consumer connections share the tunnel's cache.
    for (var i = 0; i < 3; i++) {
      final r = await get(t, '/static');
      expect(r.$2, 'static body');
      expect(r.$3.value('x-cache'), 'HIT');
    }
    expect(hits['/static'], 1);

    // Uncacheable responses keep reaching the target.
    expect((await get(t, '/dyn')).$2, 'dynamic 1');
    expect((await get(t, '/dyn')).$2, 'dynamic 2');
    await get(t, '/nocc');
    await get(t, '/nocc');
    expect(hits['/nocc'], 2, reason: 'no Cache-Control and no default TTL');

    final listed = (await client.listTunnels()).single;
    expect(listed.cache!.maxBytes, 32 * _mib);
    expect(listed.cacheStats!.hits, 3);
    expect(listed.cacheStats!.entries, 1);
    expect(listed.cacheStats!.bytes, greaterThan(0));
    expect(listed.timeouts!.isDefault, isTrue);
  });

  test(
    'private only with cachePrivate; never Set-Cookie or Authorization',
    () async {
      final client = await start();
      final plain = await client.openTunnel(
        nodeId: 'web-01',
        targetPort: target.port,
        protocol: TunnelProtocol.http,
        cache: const TunnelCacheOptions(),
      );
      await get(plain, '/private');
      await get(plain, '/private');
      expect(hits['/private'], 2);

      final priv = await client.openTunnel(
        nodeId: 'web-01',
        targetPort: target.port,
        protocol: TunnelProtocol.http,
        cache: const TunnelCacheOptions(cachePrivate: true),
      );
      expect(priv.cache!.cachePrivate, isTrue);
      await get(priv, '/private');
      final again = await get(priv, '/private');
      expect(again.$3.value('x-cache'), 'HIT');
      expect(hits['/private'], 3);

      await get(priv, '/cookie');
      await get(priv, '/cookie');
      expect(hits['/cookie'], 2);

      final authed = await get(
        priv,
        '/static',
        headers: {'authorization': 'Bearer x'},
      );
      expect(authed.$3.value('x-cache'), 'BYPASS');
    },
  );

  test('a default TTL caches responses without Cache-Control', () async {
    final client = await start();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
      cache: const TunnelCacheOptions(defaultTtl: Duration(minutes: 5)),
    );
    expect(t.cache!.defaultTtl, const Duration(minutes: 5));
    await get(t, '/nocc');
    expect((await get(t, '/nocc')).$3.value('x-cache'), 'HIT');
    expect(hits['/nocc'], 1);
  });

  test('the Hub lowers an oversized cache to its per-tunnel limit', () async {
    final client = await start(perTunnel: _mib);
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
      cache: const TunnelCacheOptions(maxBytes: 1024 * _mib),
    );
    expect(t.cache!.maxBytes, _mib);
    expect(t.cache!.maxEntryBytes, _mib, reason: 'clamped to the cache size');
  });

  test(
    'a Hub with caching disabled opens the tunnel without a cache',
    () async {
      final client = await start(total: 0);
      final t = await client.openTunnel(
        nodeId: 'web-01',
        targetPort: target.port,
        protocol: TunnelProtocol.http,
        cache: const TunnelCacheOptions(),
      );
      expect(t.cache, isNull);
      final r = await get(t, '/static');
      expect(r.$2, 'static body');
      expect(r.$3.value('x-cache'), isNull);
      await get(t, '/static');
      expect(hits['/static'], 2);
    },
  );

  test('caching and timeouts are refused on a plain TCP tunnel', () async {
    final client = await start();
    for (final open in [
      () => client.openTunnel(
        nodeId: 'web-01',
        targetPort: target.port,
        cache: const TunnelCacheOptions(),
      ),
      () => client.openTunnel(
        nodeId: 'web-01',
        targetPort: target.port,
        timeouts: const TunnelHttpTimeouts(),
      ),
    ]) {
      await expectLater(
        open(),
        throwsA(
          isA<TunnelRejectedException>().having(
            (e) => e.code,
            'code',
            'requires_http',
          ),
        ),
      );
    }
  });

  test('a silent target gets 504 after the response-header timeout', () async {
    final client = await start();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
      timeouts: const TunnelHttpTimeouts(
        responseHeader: Duration(milliseconds: 400),
      ),
    );
    expect(t.timeouts!.responseHeader, const Duration(milliseconds: 400));
    final sw = Stopwatch()..start();
    final r = await get(t, '/hang');
    expect(r.$1, 504);
    expect(r.$2, '504 Gateway Timeout\n');
    expect(r.$3.value('connection'), 'close');
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    // The tunnel keeps working for new connections.
    expect((await get(t, '/dyn')).$1, 200);
  });

  test('a target that drops the connection yields 502', () async {
    final client = await start();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
    );
    final r = await get(t, '/close');
    expect(r.$1, 502);
    expect(r.$2, '502 Bad Gateway\n');
  });

  test('a target that refuses the connection yields 502', () async {
    final client = await start();
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: closedPort,
      protocol: TunnelProtocol.http,
    );
    final r = await get(t, '/anything');
    expect(r.$1, 502);
  });

  test('closing the tunnel gives its cache memory back', () async {
    final client = await start();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
      cache: const TunnelCacheOptions(),
    );
    await get(t, '/static');
    final budget = cluster.hub.broker.tunnelCacheBudget;
    expect(budget.usedBytes, greaterThan(0));
    await client.closeTunnel(t.tunnelId);
    expect(budget.usedBytes, 0);
  });

  test('a cached @local HTTP tunnel works too', () async {
    final client = await start();
    final t = await client.openTunnel(
      targetPort: target.port,
      local: true,
      protocol: TunnelProtocol.http,
      cache: const TunnelCacheOptions(),
    );
    await get(t, '/static');
    expect((await get(t, '/static')).$3.value('x-cache'), 'HIT');
    expect(hits['/static'], 1);
  });

  test('pipelined requests on one connection keep their order', () async {
    final client = await start();
    final t = await client.openTunnel(
      nodeId: 'web-01',
      targetPort: target.port,
      protocol: TunnelProtocol.http,
      cache: const TunnelCacheOptions(),
    );
    await get(t, '/static'); // warm
    final s = await Socket.connect(InternetAddress.loopbackIPv4, t.publicPort);
    addTearDown(s.destroy);
    final out = StringBuffer();
    final done = Completer<void>();
    s.listen((d) {
      out.write(latin1.decode(d));
      final text = out.toString();
      if (text.contains('dynamic 2') &&
          text.endsWith('0\r\n\r\n') &&
          !done.isCompleted) {
        done.complete();
      }
    });
    s.write(
      'GET /p HTTP/1.1\r\nHost: h\r\n\r\n'
      'GET /static HTTP/1.1\r\nHost: h\r\n\r\n'
      'GET /p HTTP/1.1\r\nHost: h\r\n\r\n',
    );
    await done.future.timeout(const Duration(seconds: 15));
    final text = out.toString();
    expect(text.indexOf('dynamic 1'), lessThan(text.indexOf('static body')));
    expect(text.indexOf('static body'), lessThan(text.indexOf('dynamic 2')));
  });
}
