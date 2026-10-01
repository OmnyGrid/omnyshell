import '../../domain/entities/tunnel_info.dart';
import '../../shared/utils/units.dart';
import 'client_runtime.dart';

/// The HTTP-tunnel options parsed from `omnyshell tunnel open` / `:tunnel`.
typedef TunnelHttpOptions = ({
  TunnelCacheOptions? cache,
  TunnelHttpTimeouts? timeouts,
});

/// Builds the cache and timeout options from raw flag values.
///
/// Any `--cache-*` value implies `--cache`. Timeouts not given keep their
/// defaults (60s response header, 5m idle, 60s client header, no max
/// duration); when none is given the result's `timeouts` is `null` so the Hub
/// applies its own defaults. Every option requires `--protocol http`.
///
/// Throws a [FormatException] whose message is ready to show the user.
TunnelHttpOptions parseTunnelHttpOptions({
  required TunnelProtocol protocol,
  bool cache = false,
  bool cachePrivate = false,
  String? cacheSize,
  String? cacheMaxEntry,
  String? cacheDefaultTtl,
  String? responseHeaderTimeout,
  String? idleTimeout,
  String? clientTimeout,
  String? maxDuration,
}) {
  bool given(String? v) => v != null && v.trim().isNotEmpty;
  final wantsCache =
      cache ||
      cachePrivate ||
      given(cacheSize) ||
      given(cacheMaxEntry) ||
      given(cacheDefaultTtl);
  final wantsTimeouts =
      given(responseHeaderTimeout) ||
      given(idleTimeout) ||
      given(clientTimeout) ||
      given(maxDuration);
  if ((wantsCache || wantsTimeouts) && protocol != TunnelProtocol.http) {
    throw const FormatException(
      '--cache and the --http-* timeouts need --protocol http',
    );
  }

  int? size(String flag, String? raw) {
    if (!given(raw)) return null;
    final v = parseByteSize(raw!);
    if (v == null || v <= 0) {
      throw FormatException('invalid $flag "$raw" (e.g. 32MiB, 512KiB)');
    }
    return v;
  }

  Duration? duration(String flag, String? raw) {
    if (!given(raw)) return null;
    final v = parseDurationArg(raw!);
    if (v == null) {
      throw FormatException('invalid $flag "$raw" (e.g. 30s, 5m, 1h, or 0)');
    }
    return v;
  }

  TunnelCacheOptions? cacheOptions;
  if (wantsCache) {
    final ttl = duration('--cache-default-ttl', cacheDefaultTtl);
    cacheOptions = TunnelCacheOptions(
      maxBytes: size('--cache-size', cacheSize),
      maxEntryBytes: size('--cache-max-entry', cacheMaxEntry),
      cachePrivate: cachePrivate,
      defaultTtl: ttl == Duration.zero ? null : ttl,
    );
  }

  TunnelHttpTimeouts? timeouts;
  if (wantsTimeouts) {
    const d = TunnelHttpTimeouts();
    final max = duration('--http-max-duration', maxDuration);
    timeouts = TunnelHttpTimeouts(
      responseHeader:
          duration('--http-response-header-timeout', responseHeaderTimeout) ??
          d.responseHeader,
      idle: duration('--http-idle-timeout', idleTimeout) ?? d.idle,
      clientHeader:
          duration('--http-client-timeout', clientTimeout) ?? d.clientHeader,
      maxDuration: max == Duration.zero ? null : max,
    );
  }
  return (cache: cacheOptions, timeouts: timeouts);
}

/// The lines to print after an HTTP tunnel opened: what cache was granted
/// (and whether the Hub lowered or refused it) and any non-default timeouts.
List<String> describeTunnelHttp(
  TunnelHandle t, {
  TunnelCacheOptions? requestedCache,
}) {
  final lines = <String>[];
  final granted = t.cache;
  if (requestedCache != null && granted == null) {
    lines.add(
      'warning: the Hub does not cache tunnels (disabled or not supported); '
      'opened without a cache',
    );
  }
  if (granted != null) {
    final size = granted.maxBytes ?? 0;
    final asked = requestedCache?.maxBytes;
    final parts = [
      'in memory, ${formatByteSize(size)}',
      if (granted.maxEntryBytes != null)
        'max entry ${formatByteSize(granted.maxEntryBytes!)}',
      if (granted.cachePrivate) 'private responses too',
      if (granted.defaultTtl != null)
        'default TTL ${formatDurationArg(granted.defaultTtl!)}',
    ];
    final clamped = asked != null && asked > size
        ? ' (requested ${formatByteSize(asked)}, limited by the Hub)'
        : '';
    lines.add('cache: ${parts.join(', ')}$clamped');
  }
  final timeouts = t.timeouts;
  if (timeouts != null && !timeouts.isDefault) {
    lines.add('timeouts: ${describeTimeouts(timeouts)}');
  }
  return lines;
}

/// `response header 60s, idle 5m, client header 60s, max off`.
String describeTimeouts(TunnelHttpTimeouts t) {
  String v(Duration? d) =>
      d == null || d == Duration.zero ? 'off' : formatDurationArg(d);
  return 'response header ${v(t.responseHeader)}, idle ${v(t.idle)}, '
      'client header ${v(t.clientHeader)}, max ${v(t.maxDuration)}';
}

/// A compact cache summary for listings, e.g.
/// `cache 1.2 MiB/32 MiB · 340 hit / 41 miss`, or `null` without a cache.
String? describeTunnelCache(TunnelInfo t) {
  final c = t.cache;
  if (c == null) return null;
  final s = t.cacheStats ?? const TunnelCacheStats();
  return 'cache ${formatByteSize(s.bytes)}/${formatByteSize(c.maxBytes ?? 0)}'
      ' · ${s.hits} hit / ${s.misses} miss';
}
