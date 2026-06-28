/// Resolves the platform-default [ConnectionFactory].
///
/// On the Dart VM (`dart.library.io` available, `js_interop` not) this exports
/// the `dart:io` implementation, which dials a `wss://` socket with full TLS.
/// On the web (`dart.library.js_interop` available) it exports the browser
/// implementation built on the platform WebSocket. Either way the importing
/// library only ever sees the browser-safe [ConnectionFactory] typedef and the
/// top-level [defaultConnectionFactory] symbol.
library;

export 'connection_factory.dart';
export 'transport_factory_io.dart'
    if (dart.library.js_interop) 'transport_factory_web.dart';
