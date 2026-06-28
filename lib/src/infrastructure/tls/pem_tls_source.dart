import 'dart:async';
import 'dart:io';

/// Loads and hot-reloads a TLS [SecurityContext] from a directory holding
/// `fullchain.pem` + `privkey.pem` (the LetsEncrypt layout).
///
/// Used both for the Hub's main listener and to terminate TLS on secure tunnel
/// public ports. [start] schedules a periodic check (defaulting to twice a day)
/// that rebuilds the context whenever either file's content changes, so
/// certificate renewals are picked up without restarting the Hub. A failed
/// reload (missing/partial/invalid files mid-renewal) is logged and skipped,
/// leaving the previous good context in place.
class PemTlsSource {
  /// The directory holding `fullchain.pem` and `privkey.pem`.
  final String directory;

  /// How often [start] checks the files for changes. Kept below a day so a
  /// renewal is always picked up within 24h.
  final Duration checkInterval;

  /// A human label for diagnostics (e.g. `'hub TLS'`, `'tunnel TLS'`), used in
  /// the reload log line.
  final String label;

  /// Optional diagnostic logger.
  final void Function(String message)? logger;

  /// Invoked with the freshly-built context after each successful reload.
  final void Function(SecurityContext context)? onReloaded;

  final String _chainPath;
  final String _keyPath;

  SecurityContext? _context;
  List<int>? _chainBytes;
  List<int>? _keyBytes;
  Timer? _timer;

  /// Creates a source reading `fullchain.pem` + `privkey.pem` from [directory].
  PemTlsSource(
    this.directory, {
    this.checkInterval = const Duration(hours: 12),
    this.label = 'TLS',
    this.logger,
    this.onReloaded,
  }) : _chainPath = '$directory/fullchain.pem',
       _keyPath = '$directory/privkey.pem';

  /// The current TLS context (valid after [load]).
  SecurityContext? get context => _context;

  /// Performs the initial load. Throws when the files are missing or invalid so
  /// the Hub fails fast at startup.
  void load() {
    final chain = File(_chainPath).readAsBytesSync();
    final key = File(_keyPath).readAsBytesSync();
    _context = SecurityContext()
      ..useCertificateChain(_chainPath)
      ..usePrivateKey(_keyPath);
    _chainBytes = chain;
    _keyBytes = key;
  }

  /// Begins periodic reload checks.
  void start() {
    _timer ??= Timer.periodic(checkInterval, (_) => reloadIfChanged());
  }

  /// Stops periodic reload checks.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Rebuilds the context when the certificate files have changed on disk.
  /// Returns `true` when a reload happened. Errors are swallowed (logged) so a
  /// renewal caught mid-write keeps serving with the previous context.
  bool reloadIfChanged() {
    try {
      final chain = File(_chainPath).readAsBytesSync();
      final key = File(_keyPath).readAsBytesSync();
      if (_chainBytes != null &&
          _keyBytes != null &&
          _bytesEqual(chain, _chainBytes!) &&
          _bytesEqual(key, _keyBytes!)) {
        return false;
      }
      final ctx = SecurityContext()
        ..useCertificateChain(_chainPath)
        ..usePrivateKey(_keyPath);
      _context = ctx;
      _chainBytes = chain;
      _keyBytes = key;
      logger?.call('$label certificate reloaded from $directory');
      onReloaded?.call(ctx);
      return true;
    } on Object catch (e) {
      logger?.call('$label reload skipped: $e');
      return false;
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
