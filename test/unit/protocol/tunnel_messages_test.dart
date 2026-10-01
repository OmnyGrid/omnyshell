import 'package:omnyshell/omnyshell.dart';
import 'package:omnyshell/omnyshell_client.dart' show TunnelHandle;
import 'package:test/test.dart';

void main() {
  late FrameCodec codec;

  setUp(() => codec = FrameCodec.standard());

  T roundTrip<T extends ControlMessage>(T message) =>
      codec.decodeControl(codec.encodeControl(message)).message as T;

  group('tunnel lifecycle messages', () {
    test('round-trips TunnelOpenRequest with an explicit public port', () {
      final decoded = roundTrip(
        const TunnelOpenRequest(
          requestId: 'r1',
          nodeId: 'web-01',
          targetPort: 3000,
          publicPort: 20080,
        ),
      );
      expect(decoded.requestId, 'r1');
      expect(decoded.nodeId, 'web-01');
      expect(decoded.targetHost, 'localhost');
      expect(decoded.targetPort, 3000);
      expect(decoded.publicPort, 20080);
    });

    test('round-trips TunnelOpenRequest without a public port (dynamic)', () {
      final decoded = roundTrip(
        const TunnelOpenRequest(
          requestId: 'r2',
          nodeId: TunnelOpenRequest.localNode,
          targetPort: 8080,
        ),
      );
      expect(decoded.nodeId, '@local');
      expect(decoded.publicPort, isNull);
    });

    test('round-trips TunnelOpened / TunnelRejected', () {
      final opened = roundTrip(
        const TunnelOpened(
          requestId: 'r1',
          tunnelId: 'tid',
          publicHost: '127.0.0.1',
          publicPort: 20080,
        ),
      );
      expect(opened.tunnelId, 'tid');
      expect(opened.publicPort, 20080);

      final rejected = roundTrip(
        const TunnelRejected(
          requestId: 'r1',
          reason: 'port_out_of_range',
          message: 'nope',
        ),
      );
      expect(rejected.reason, 'port_out_of_range');
      expect(rejected.message, 'nope');
    });

    test('round-trips close + list messages, including TunnelInfo', () {
      final close = roundTrip(
        const TunnelCloseRequest(requestId: 'r1', tunnelRef: 'tid'),
      );
      expect(close.tunnelRef, 'tid');

      final list = roundTrip(
        TunnelListResponse(
          requestId: 'r1',
          tunnels: [
            TunnelInfo(
              tunnelId: 'tid',
              nodeId: 'web-01',
              ownerUserId: 'alice',
              targetHost: 'localhost',
              targetPort: 3000,
              publicHost: '127.0.0.1',
              publicPort: 20080,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ],
        ),
      );
      expect(list.tunnels, hasLength(1));
      expect(list.tunnels.single.tunnelId, 'tid');
      expect(list.tunnels.single.publicPort, 20080);
    });
  });

  group('tunnel data-channel messages', () {
    test('round-trips NodeTunnelConnect preserving the channel id', () {
      final connect = NodeTunnelConnect(
        channel: 9,
        tunnelId: 'tid',
        targetHost: '127.0.0.1',
        targetPort: 3000,
        principal: 'alice',
      );
      final encoded = codec.encodeControl(connect);
      final decoded = codec.decodeControl(encoded).message as NodeTunnelConnect;
      expect(decoded.channel, 9);
      expect(decoded.targetPort, 3000);
      expect(decoded.principal, 'alice');
    });

    test('round-trips NodeTunnelConnected / NodeTunnelConnectFailed', () {
      final ok = roundTrip(
        const NodeTunnelConnected(channel: 9, tunnelId: 'tid'),
      );
      expect(ok.channel, 9);

      final failed = roundTrip(
        const NodeTunnelConnectFailed(
          channel: 9,
          tunnelId: 'tid',
          reason: 'dial_failed',
          message: 'refused',
        ),
      );
      expect(failed.reason, 'dial_failed');
      expect(failed.message, 'refused');
    });
  });

  group('tunnel protocol', () {
    test('TunnelProtocol.parse: missing is tcp, unknown is null', () {
      expect(TunnelProtocol.parse(null), TunnelProtocol.tcp);
      expect(TunnelProtocol.parse('tcp'), TunnelProtocol.tcp);
      expect(TunnelProtocol.parse('http'), TunnelProtocol.http);
      expect(TunnelProtocol.parse('HTTP'), TunnelProtocol.http);
      expect(TunnelProtocol.parse('ftp'), isNull);
      expect(TunnelProtocol.http.wireName, 'http');
    });

    test('TunnelOpenRequest round-trips http and omits the tcp default', () {
      const http = TunnelOpenRequest(
        requestId: 'r',
        nodeId: 'n',
        targetPort: 80,
        protocol: TunnelProtocol.http,
      );
      expect(http.toJson()['protocol'], 'http');
      expect(roundTrip(http).protocol, TunnelProtocol.http);

      const tcp = TunnelOpenRequest(requestId: 'r', nodeId: 'n', targetPort: 1);
      expect(tcp.toJson().containsKey('protocol'), isFalse);
      expect(roundTrip(tcp).protocol, TunnelProtocol.tcp);
    });

    test('TunnelOpenRequest decodes an unknown protocol as null', () {
      final d = TunnelOpenRequest.fromJson(null, {
        'requestId': 'r',
        'nodeId': 'n',
        'targetPort': 80,
        'protocol': 'quic',
      });
      expect(d.protocol, isNull);
      expect(d.toJson().containsKey('protocol'), isFalse);
    });

    test('TunnelOpened round-trips http; an old Hub decodes as tcp', () {
      final opened = roundTrip(
        const TunnelOpened(
          requestId: 'r',
          tunnelId: 't',
          publicHost: '',
          publicPort: 1,
          protocol: TunnelProtocol.http,
        ),
      );
      expect(opened.protocol, TunnelProtocol.http);

      final legacy = TunnelOpened.fromJson(null, {
        'requestId': 'r',
        'tunnelId': 't',
        'publicPort': 1,
      });
      expect(legacy.protocol, TunnelProtocol.tcp);
      final future = TunnelOpened.fromJson(null, {
        'requestId': 'r',
        'tunnelId': 't',
        'publicPort': 1,
        'protocol': 'quic',
      });
      expect(future.protocol, TunnelProtocol.tcp);
    });

    TunnelInfo info({bool secure = false, TunnelProtocol? protocol}) =>
        TunnelInfo(
          tunnelId: 't',
          nodeId: 'n',
          ownerUserId: 'u',
          targetHost: 'localhost',
          targetPort: 80,
          publicHost: '',
          publicPort: 1,
          createdAt: DateTime.utc(2026),
          secure: secure,
          protocol: protocol ?? TunnelProtocol.tcp,
        );

    test('TunnelInfo carries protocol over JSON and derives the scheme', () {
      final http = info(protocol: TunnelProtocol.http);
      expect(http.toJson()['protocol'], 'http');
      expect(TunnelInfo.fromJson(http.toJson()).protocol, TunnelProtocol.http);
      expect(info().toJson().containsKey('protocol'), isFalse);
      expect(TunnelInfo.fromJson(info().toJson()).protocol, TunnelProtocol.tcp);

      expect(info().scheme, isNull);
      expect(http.scheme, 'http');
      expect(info(secure: true).scheme, 'https');
      expect(info(secure: true, protocol: TunnelProtocol.http).scheme, 'https');
    });

    test('TunnelHandle.publicAddress substitutes the Hub host', () {
      const tcp = TunnelHandle(
        tunnelId: 't',
        nodeId: 'n',
        publicHost: '',
        publicPort: 9,
        targetPort: 80,
      );
      expect(tcp.scheme, isNull);
      expect(tcp.publicAddress('hub'), 'hub:9');

      const http = TunnelHandle(
        tunnelId: 't',
        nodeId: 'n',
        publicHost: 'pub',
        publicPort: 9,
        targetPort: 80,
        protocol: TunnelProtocol.http,
      );
      expect(http.publicAddress('hub'), 'http://pub:9');

      const tls = TunnelHandle(
        tunnelId: 't',
        nodeId: 'n',
        publicHost: '',
        publicPort: 9,
        targetPort: 80,
        secure: true,
      );
      expect(tls.publicAddress('hub'), 'https://hub:9');
    });
  });

  group('tunnel cache and timeouts', () {
    const cache = TunnelCacheOptions(
      maxBytes: 1000,
      maxEntryBytes: 100,
      cachePrivate: true,
      defaultTtl: Duration(minutes: 5),
    );
    const timeouts = TunnelHttpTimeouts(
      responseHeader: Duration(seconds: 30),
      idle: Duration.zero,
      clientHeader: Duration(seconds: 10),
      maxDuration: Duration(minutes: 2),
    );

    void expectCache(TunnelCacheOptions? c) {
      expect(c, isNotNull);
      expect(c!.maxBytes, 1000);
      expect(c.maxEntryBytes, 100);
      expect(c.cachePrivate, isTrue);
      expect(c.defaultTtl, const Duration(minutes: 5));
    }

    void expectTimeouts(TunnelHttpTimeouts? t) {
      expect(t, isNotNull);
      expect(t!.responseHeader, const Duration(seconds: 30));
      expect(t.idle, Duration.zero);
      expect(t.clientHeader, const Duration(seconds: 10));
      expect(t.maxDuration, const Duration(minutes: 2));
      expect(t.isDefault, isFalse);
    }

    test('TunnelOpenRequest and TunnelOpened round-trip both', () {
      final req = roundTrip(
        const TunnelOpenRequest(
          requestId: 'r',
          nodeId: 'n',
          targetPort: 80,
          protocol: TunnelProtocol.http,
          cache: cache,
          timeouts: timeouts,
        ),
      );
      expectCache(req.cache);
      expectTimeouts(req.timeouts);

      final opened = roundTrip(
        const TunnelOpened(
          requestId: 'r',
          tunnelId: 't',
          publicHost: '',
          publicPort: 1,
          protocol: TunnelProtocol.http,
          cache: cache,
          timeouts: timeouts,
        ),
      );
      expectCache(opened.cache);
      expectTimeouts(opened.timeouts);
    });

    test('absent fields stay absent; defaults fill a partial object', () {
      const plain = TunnelOpenRequest(
        requestId: 'r',
        nodeId: 'n',
        targetPort: 1,
      );
      expect(plain.toJson().containsKey('cache'), isFalse);
      expect(plain.toJson().containsKey('timeouts'), isFalse);
      expect(roundTrip(plain).cache, isNull);
      expect(roundTrip(plain).timeouts, isNull);

      expect(const TunnelCacheOptions().toJson(), isEmpty);
      final partial = TunnelHttpTimeouts.fromJson({'idleMs': 1000});
      expect(partial.idle, const Duration(seconds: 1));
      expect(partial.responseHeader, const Duration(seconds: 60));
      expect(partial.maxDuration, isNull);
      expect(const TunnelHttpTimeouts().isDefault, isTrue);
      expect(
        const TunnelHttpTimeouts().toJson().containsKey('maxDurationMs'),
        isFalse,
      );
    });

    test('non-object values decode as absent', () {
      expect(TunnelCacheOptions.optFrom({'cache': 'yes'}, 'cache'), isNull);
      expect(TunnelHttpTimeouts.optFrom({'t': 3}, 't'), isNull);
      expect(TunnelCacheStats.optFrom({'s': []}, 's'), isNull);
    });

    test('TunnelInfo carries cache, stats and timeouts', () {
      final info = TunnelInfo(
        tunnelId: 't',
        nodeId: 'n',
        ownerUserId: 'u',
        targetHost: 'localhost',
        targetPort: 80,
        publicHost: '',
        publicPort: 1,
        createdAt: DateTime.utc(2026),
        protocol: TunnelProtocol.http,
        cache: cache,
        cacheStats: const TunnelCacheStats(
          entries: 1,
          bytes: 2,
          hits: 3,
          misses: 4,
          revalidated: 5,
          bypassed: 6,
        ),
        timeouts: timeouts,
      );
      final back = TunnelInfo.fromJson(info.toJson());
      expectCache(back.cache);
      expectTimeouts(back.timeouts);
      final s = back.cacheStats!;
      expect(
        [s.entries, s.bytes, s.hits, s.misses, s.revalidated, s.bypassed],
        [1, 2, 3, 4, 5, 6],
      );
      final bare = TunnelInfo.fromJson(
        TunnelInfo(
          tunnelId: 't',
          nodeId: 'n',
          ownerUserId: 'u',
          targetHost: 'localhost',
          targetPort: 80,
          publicHost: '',
          publicPort: 1,
          createdAt: DateTime.utc(2026),
        ).toJson(),
      );
      expect(bare.cache, isNull);
      expect(bare.cacheStats, isNull);
      expect(bare.timeouts, isNull);
    });
  });
}
