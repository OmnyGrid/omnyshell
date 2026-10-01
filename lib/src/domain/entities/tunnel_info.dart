import 'package:meta/meta.dart';

import '../../shared/json/json_codec_helpers.dart';

/// The application protocol a tunnel carries, which decides whether the Hub
/// looks inside the stream.
enum TunnelProtocol {
  /// Opaque TCP: bytes are relayed untouched (the default).
  tcp,

  /// HTTP/1.x: the Hub adds forwarding headers (client address, `http` or
  /// `https`, host, port, tunnel context) to every request it relays to the
  /// target. Responses, bodies and upgraded (WebSocket) streams are untouched.
  http;

  /// The wire / CLI name (`tcp`, `http`).
  String get wireName => name;

  /// Parses a wire / CLI name; a missing value is [tcp] and an unknown one
  /// `null`, so a peer can tell "not asked" from "asked for something I don't
  /// support".
  static TunnelProtocol? parse(String? value) => value == null
      ? tcp
      : values.where((p) => p.wireName == value.toLowerCase()).firstOrNull;
}

Duration? _optMillis(Map<String, dynamic> d, String key) {
  final ms = Json.optInt(d, key);
  return ms == null ? null : Duration(milliseconds: ms);
}

/// The in-memory response cache of an HTTP tunnel (RFC 9111), held by the Hub.
///
/// In a request, a `null` size means "the Hub's per-tunnel default"; in the
/// Hub's reply ([TunnelHandle] / [TunnelInfo]) both sizes are the values the
/// Hub actually granted, after clamping to its limits.
@immutable
class TunnelCacheOptions {
  /// The most bytes the tunnel's cache may hold (`null`: the Hub's default).
  final int? maxBytes;

  /// The largest single response stored (`null`: 8 MiB); bigger ones are
  /// relayed but not kept.
  final int? maxEntryBytes;

  /// Also cache `Cache-Control: private` responses. They are then shared by
  /// every consumer of the tunnel; responses that set a cookie and requests
  /// that carry `Authorization` are still never cached.
  final bool cachePrivate;

  /// Freshness given to responses that state none (no `max-age`/`s-maxage`/
  /// `Expires`). `null` leaves them uncached.
  final Duration? defaultTtl;

  /// The default largest-entry size.
  static const int defaultMaxEntryBytes = 8 * 1024 * 1024;

  /// Creates cache options.
  const TunnelCacheOptions({
    this.maxBytes,
    this.maxEntryBytes,
    this.cachePrivate = false,
    this.defaultTtl,
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    if (maxBytes != null) 'maxBytes': maxBytes,
    if (maxEntryBytes != null) 'maxEntryBytes': maxEntryBytes,
    if (cachePrivate) 'cachePrivate': true,
    if (defaultTtl != null) 'defaultTtlMs': defaultTtl!.inMilliseconds,
  };

  /// Decodes from JSON.
  static TunnelCacheOptions fromJson(Map<String, dynamic> d) =>
      TunnelCacheOptions(
        maxBytes: Json.optInt(d, 'maxBytes'),
        maxEntryBytes: Json.optInt(d, 'maxEntryBytes'),
        cachePrivate: Json.optBool(d, 'cachePrivate'),
        defaultTtl: _optMillis(d, 'defaultTtlMs'),
      );

  /// Decodes the optional object at [key], or `null`.
  static TunnelCacheOptions? optFrom(Map<String, dynamic> d, String key) {
    final v = d[key];
    return v is Map ? fromJson(Json.asObject(v, key)) : null;
  }
}

/// The time limits the Hub enforces on an HTTP tunnel, per consumer request.
/// [Duration.zero] turns a limit off.
@immutable
class TunnelHttpTimeouts {
  /// From a request being fully sent to the target's response head being
  /// complete; on expiry the consumer gets `504` and the connection closes.
  final Duration responseHeader;

  /// The longest silence between response bytes once a response started; on
  /// expiry the connection closes.
  final Duration idle;

  /// From the first byte of a consumer's request head to its end (idle
  /// keep-alive time is not counted); on expiry the consumer gets `408`.
  final Duration clientHeader;

  /// A cap on a whole exchange, or `null` for none: `504` if no response byte
  /// was sent yet, otherwise a close.
  final Duration? maxDuration;

  /// Creates timeouts; the defaults are 60s / 5m / 60s / none.
  const TunnelHttpTimeouts({
    this.responseHeader = const Duration(seconds: 60),
    this.idle = const Duration(minutes: 5),
    this.clientHeader = const Duration(seconds: 60),
    this.maxDuration,
  });

  /// Whether every field holds its default.
  bool get isDefault =>
      responseHeader == const Duration(seconds: 60) &&
      idle == const Duration(minutes: 5) &&
      clientHeader == const Duration(seconds: 60) &&
      maxDuration == null;

  /// Encodes to JSON (milliseconds).
  Map<String, dynamic> toJson() => {
    'responseHeaderMs': responseHeader.inMilliseconds,
    'idleMs': idle.inMilliseconds,
    'clientHeaderMs': clientHeader.inMilliseconds,
    if (maxDuration != null) 'maxDurationMs': maxDuration!.inMilliseconds,
  };

  /// Decodes from JSON; a missing field takes its default.
  static TunnelHttpTimeouts fromJson(Map<String, dynamic> d) {
    const defaults = TunnelHttpTimeouts();
    return TunnelHttpTimeouts(
      responseHeader:
          _optMillis(d, 'responseHeaderMs') ?? defaults.responseHeader,
      idle: _optMillis(d, 'idleMs') ?? defaults.idle,
      clientHeader: _optMillis(d, 'clientHeaderMs') ?? defaults.clientHeader,
      maxDuration: _optMillis(d, 'maxDurationMs'),
    );
  }

  /// Decodes the optional object at [key], or `null`.
  static TunnelHttpTimeouts? optFrom(Map<String, dynamic> d, String key) {
    final v = d[key];
    return v is Map ? fromJson(Json.asObject(v, key)) : null;
  }
}

/// Live counters of a tunnel's cache.
@immutable
class TunnelCacheStats {
  /// Stored responses.
  final int entries;

  /// Bytes held.
  final int bytes;

  /// Requests answered from the cache.
  final int hits;

  /// Cacheable requests sent to the target.
  final int misses;

  /// Stale entries confirmed by the target (`304`).
  final int revalidated;

  /// Requests that could not use the cache.
  final int bypassed;

  /// Creates stats.
  const TunnelCacheStats({
    this.entries = 0,
    this.bytes = 0,
    this.hits = 0,
    this.misses = 0,
    this.revalidated = 0,
    this.bypassed = 0,
  });

  /// Encodes to JSON.
  Map<String, dynamic> toJson() => {
    'entries': entries,
    'bytes': bytes,
    'hits': hits,
    'misses': misses,
    'revalidated': revalidated,
    'bypassed': bypassed,
  };

  /// Decodes the optional object at [key], or `null`.
  static TunnelCacheStats? optFrom(Map<String, dynamic> d, String key) {
    final v = d[key];
    if (v is! Map) return null;
    final m = Json.asObject(v, key);
    return TunnelCacheStats(
      entries: Json.optInt(m, 'entries') ?? 0,
      bytes: Json.optInt(m, 'bytes') ?? 0,
      hits: Json.optInt(m, 'hits') ?? 0,
      misses: Json.optInt(m, 'misses') ?? 0,
      revalidated: Json.optInt(m, 'revalidated') ?? 0,
      bypassed: Json.optInt(m, 'bypassed') ?? 0,
    );
  }
}

/// A user-facing view of an active TCP tunnel held by the Hub, as returned by
/// the list API and relayed to the owning client.
///
/// A tunnel publishes an internal `targetHost:targetPort` (reachable by the
/// exposer — a node or the client's own machine) on a public `publicPort` the
/// Hub listens on. External TCP connections to `publicHost:publicPort` are
/// bridged to the target over the exposer's multiplexed connection.
@immutable
class TunnelInfo {
  /// The full, cryptographically-secure tunnel id.
  final String tunnelId;

  /// The node that exposes the target, or `@local` when the owning client
  /// exposes its own machine.
  final String nodeId;

  /// The authenticated principal that owns the tunnel.
  final String ownerUserId;

  /// The internal host the exposer dials for each connection.
  final String targetHost;

  /// The internal TCP port the exposer dials for each connection.
  final int targetPort;

  /// The host the Hub advertises for the public listener (may be empty/wildcard,
  /// in which case clients substitute the Hub's own hostname).
  final String publicHost;

  /// The public TCP port the Hub listens on for this tunnel.
  final int publicPort;

  /// Whether the public port terminates TLS (HTTPS).
  final bool secure;

  /// The application protocol the tunnel carries.
  final TunnelProtocol protocol;

  /// The granted response cache (HTTP tunnels), or `null` for none.
  final TunnelCacheOptions? cache;

  /// The cache's live counters, when [cache] is set.
  final TunnelCacheStats? cacheStats;

  /// The enforced HTTP timeouts (HTTP tunnels), or `null` for plain TCP.
  final TunnelHttpTimeouts? timeouts;

  /// When the tunnel was opened.
  final DateTime createdAt;

  /// Creates a tunnel view.
  const TunnelInfo({
    required this.tunnelId,
    required this.nodeId,
    required this.ownerUserId,
    required this.targetHost,
    required this.targetPort,
    required this.publicHost,
    required this.publicPort,
    required this.createdAt,
    this.secure = false,
    this.protocol = TunnelProtocol.tcp,
    this.cache,
    this.cacheStats,
    this.timeouts,
  });

  /// The URL scheme a consumer uses: `https`/`http` for an HTTP tunnel (or any
  /// TLS one), otherwise `null` for plain TCP.
  String? get scheme =>
      secure ? 'https' : (protocol == TunnelProtocol.http ? 'http' : null);

  /// A short, display-only handle derived from [tunnelId]. Close accepts any
  /// unambiguous prefix of [tunnelId] (the short id being one such).
  String get shortId =>
      tunnelId.length <= 8 ? tunnelId : tunnelId.substring(0, 8);

  /// Encodes this info to a JSON map.
  Map<String, dynamic> toJson() => {
    'tunnelId': tunnelId,
    'nodeId': nodeId,
    'ownerUserId': ownerUserId,
    'targetHost': targetHost,
    'targetPort': targetPort,
    'publicHost': publicHost,
    'publicPort': publicPort,
    if (secure) 'secure': true,
    if (protocol != TunnelProtocol.tcp) 'protocol': protocol.wireName,
    if (cache != null) 'cache': cache!.toJson(),
    if (cacheStats != null) 'cacheStats': cacheStats!.toJson(),
    if (timeouts != null) 'timeouts': timeouts!.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  /// Decodes a [TunnelInfo] from a JSON map.
  static TunnelInfo fromJson(Map<String, dynamic> d) => TunnelInfo(
    tunnelId: Json.requireString(d, 'tunnelId'),
    nodeId: Json.requireString(d, 'nodeId'),
    ownerUserId: Json.optString(d, 'ownerUserId') ?? '',
    targetHost: Json.optString(d, 'targetHost') ?? 'localhost',
    targetPort: Json.requireInt(d, 'targetPort'),
    publicHost: Json.optString(d, 'publicHost') ?? '',
    publicPort: Json.requireInt(d, 'publicPort'),
    secure: Json.optBool(d, 'secure'),
    protocol:
        TunnelProtocol.parse(Json.optString(d, 'protocol')) ??
        TunnelProtocol.tcp,
    cache: TunnelCacheOptions.optFrom(d, 'cache'),
    cacheStats: TunnelCacheStats.optFrom(d, 'cacheStats'),
    timeouts: TunnelHttpTimeouts.optFrom(d, 'timeouts'),
    createdAt: Json.requireTimestamp(d, 'createdAt'),
  );
}
