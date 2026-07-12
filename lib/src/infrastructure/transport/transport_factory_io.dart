import '../../protocol/omnyshell_connection.dart';
import 'frame_connection.dart';

/// The native default: dials a `wss://` WebSocket over `dart:io` with standard
/// TLS verification. TLS trust overrides (self-signed test certs, pinning) are
/// supplied explicitly via `ioConnectionFactory` in `io_connection_factory.dart`.
Future<OmnyShellConnection> defaultConnectionFactory(
  Uri uri, {
  Map<String, String>? headers,
}) => FrameConnection.connect(uri, headers: headers);
