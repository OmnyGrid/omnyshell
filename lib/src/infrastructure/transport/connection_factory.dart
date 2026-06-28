import '../../protocol/omnyshell_connection.dart';

/// Opens a transport connection to [uri], returning a connected
/// [OmnyShellConnection].
///
/// Native implementations may honour [headers] on the upgrade request; the
/// browser WebSocket API cannot send custom headers, but that is fine for
/// OmnyShell because authentication travels in-band in the `AuthRequest`
/// control frame rather than an HTTP header.
///
/// This typedef is the seam that lets [ClientRuntime] run on both the Dart VM
/// (real `dart:io` sockets with TLS) and in the browser (the platform
/// WebSocket) without either build pulling in the other's `dart:` libraries.
typedef ConnectionFactory =
    Future<OmnyShellConnection> Function(
      Uri uri, {
      Map<String, String>? headers,
    });
