import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/src/application/client/tunnel_http_options.dart';
import 'package:omnyshell/src/shared/utils/units.dart';
import 'package:test/test.dart';

void main() {
  group('parseTunnelHttpOptions', () {
    test('nothing given: no cache, Hub-default timeouts', () {
      final o = parseTunnelHttpOptions(protocol: TunnelProtocol.http);
      expect(o.cache, isNull);
      expect(o.timeouts, isNull);
      final tcp = parseTunnelHttpOptions(protocol: TunnelProtocol.tcp);
      expect(tcp.cache, isNull);
    });

    test('--cache alone leaves sizes to the Hub', () {
      final c = parseTunnelHttpOptions(
        protocol: TunnelProtocol.http,
        cache: true,
      ).cache!;
      expect(c.maxBytes, isNull);
      expect(c.maxEntryBytes, isNull);
      expect(c.cachePrivate, isFalse);
      expect(c.defaultTtl, isNull);
    });

    test('any --cache-* option implies --cache', () {
      for (final o in [
        parseTunnelHttpOptions(
          protocol: TunnelProtocol.http,
          cachePrivate: true,
        ),
        parseTunnelHttpOptions(protocol: TunnelProtocol.http, cacheSize: '1M'),
        parseTunnelHttpOptions(
          protocol: TunnelProtocol.http,
          cacheMaxEntry: '1M',
        ),
        parseTunnelHttpOptions(
          protocol: TunnelProtocol.http,
          cacheDefaultTtl: '5m',
        ),
      ]) {
        expect(o.cache, isNotNull);
      }
    });

    test('sizes, private and TTL are parsed', () {
      final c = parseTunnelHttpOptions(
        protocol: TunnelProtocol.http,
        cachePrivate: true,
        cacheSize: '16MiB',
        cacheMaxEntry: '512k',
        cacheDefaultTtl: '5m',
      ).cache!;
      expect(c.maxBytes, 16 * mib);
      expect(c.maxEntryBytes, 512 * 1024);
      expect(c.cachePrivate, isTrue);
      expect(c.defaultTtl, const Duration(minutes: 5));
    });

    test('a zero default TTL means none', () {
      final c = parseTunnelHttpOptions(
        protocol: TunnelProtocol.http,
        cacheDefaultTtl: '0',
      ).cache!;
      expect(c.defaultTtl, isNull);
    });

    test('given timeouts override defaults; the rest keep theirs', () {
      final t = parseTunnelHttpOptions(
        protocol: TunnelProtocol.http,
        responseHeaderTimeout: '30s',
        maxDuration: '10m',
      ).timeouts!;
      expect(t.responseHeader, const Duration(seconds: 30));
      expect(t.idle, const Duration(minutes: 5));
      expect(t.clientHeader, const Duration(seconds: 60));
      expect(t.maxDuration, const Duration(minutes: 10));
    });

    test('0 disables a timeout; max 0 means none', () {
      final t = parseTunnelHttpOptions(
        protocol: TunnelProtocol.http,
        idleTimeout: '0',
        clientTimeout: '0',
        maxDuration: '0',
      ).timeouts!;
      expect(t.idle, Duration.zero);
      expect(t.clientHeader, Duration.zero);
      expect(t.maxDuration, isNull);
    });

    test('everything needs --protocol http', () {
      for (final call in <void Function()>[
        () => parseTunnelHttpOptions(protocol: TunnelProtocol.tcp, cache: true),
        () => parseTunnelHttpOptions(
          protocol: TunnelProtocol.tcp,
          idleTimeout: '5s',
        ),
      ]) {
        expect(
          call,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('--protocol http'),
            ),
          ),
        );
      }
    });

    test('bad values name the flag', () {
      final bad = <String, void Function()>{
        '--cache-size': () => parseTunnelHttpOptions(
          protocol: TunnelProtocol.http,
          cacheSize: 'lots',
        ),
        '--cache-max-entry': () => parseTunnelHttpOptions(
          protocol: TunnelProtocol.http,
          cacheMaxEntry: '0',
        ),
        '--cache-default-ttl': () => parseTunnelHttpOptions(
          protocol: TunnelProtocol.http,
          cacheDefaultTtl: 'soon',
        ),
        '--http-response-header-timeout': () => parseTunnelHttpOptions(
          protocol: TunnelProtocol.http,
          responseHeaderTimeout: '5',
        ),
      };
      bad.forEach((flag, call) {
        expect(
          call,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              startsWith('invalid $flag'),
            ),
          ),
        );
      });
    });

    test('blank values count as not given', () {
      final o = parseTunnelHttpOptions(
        protocol: TunnelProtocol.tcp,
        cacheSize: ' ',
        idleTimeout: '',
      );
      expect(o.cache, isNull);
      expect(o.timeouts, isNull);
    });
  });

  group('describeTunnelHttp', () {
    TunnelHandle handle({TunnelCacheOptions? cache, TunnelHttpTimeouts? t}) =>
        TunnelHandle(
          tunnelId: 't',
          nodeId: 'n',
          publicHost: 'h',
          publicPort: 1,
          targetPort: 2,
          protocol: TunnelProtocol.http,
          cache: cache,
          timeouts: t,
        );

    test('nothing to say for a plain HTTP tunnel with default timeouts', () {
      expect(
        describeTunnelHttp(handle(t: const TunnelHttpTimeouts())),
        isEmpty,
      );
      expect(describeTunnelHttp(handle()), isEmpty);
    });

    test('the granted cache, and when the Hub lowered it', () {
      final granted = handle(
        cache: TunnelCacheOptions(
          maxBytes: 32 * mib,
          maxEntryBytes: 8 * mib,
          cachePrivate: true,
          defaultTtl: const Duration(minutes: 5),
        ),
      );
      expect(describeTunnelHttp(granted), [
        'cache: in memory, 32 MiB, max entry 8 MiB, private responses too, '
            'default TTL 5m',
      ]);
      expect(
        describeTunnelHttp(
          granted,
          requestedCache: TunnelCacheOptions(maxBytes: 1024 * mib),
        ).single,
        endsWith('(requested 1 GiB, limited by the Hub)'),
      );
      expect(
        describeTunnelHttp(
          granted,
          requestedCache: TunnelCacheOptions(maxBytes: 16 * mib),
        ).single,
        isNot(contains('limited')),
      );
    });

    test('warns when the Hub granted no cache', () {
      expect(
        describeTunnelHttp(
          handle(),
          requestedCache: const TunnelCacheOptions(),
        ).single,
        startsWith('warning: the Hub does not cache tunnels'),
      );
    });

    test('lists non-default timeouts', () {
      expect(
        describeTunnelHttp(
          handle(
            t: const TunnelHttpTimeouts(
              responseHeader: Duration(seconds: 30),
              idle: Duration.zero,
              maxDuration: Duration(minutes: 10),
            ),
          ),
        ),
        [
          'timeouts: response header 30s, idle off, client header 1m, '
              'max 10m',
        ],
      );
    });
  });

  test('describeTunnelCache', () {
    TunnelInfo info({TunnelCacheOptions? cache, TunnelCacheStats? stats}) =>
        TunnelInfo(
          tunnelId: 't',
          nodeId: 'n',
          ownerUserId: 'u',
          targetHost: 'localhost',
          targetPort: 1,
          publicHost: '',
          publicPort: 2,
          createdAt: DateTime.utc(2026),
          cache: cache,
          cacheStats: stats,
        );
    expect(describeTunnelCache(info()), isNull);
    expect(
      describeTunnelCache(
        info(
          cache: TunnelCacheOptions(maxBytes: 32 * mib),
          stats: const TunnelCacheStats(bytes: 1536, hits: 340, misses: 41),
        ),
      ),
      'cache 1.5 KiB/32 MiB · 340 hit / 41 miss',
    );
    expect(
      describeTunnelCache(info(cache: const TunnelCacheOptions())),
      'cache 0 B/0 B · 0 hit / 0 miss',
    );
  });
}
