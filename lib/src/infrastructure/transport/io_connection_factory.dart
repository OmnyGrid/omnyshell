import 'dart:io';

import 'connection_factory.dart';
import 'frame_connection.dart';

/// Builds a `dart:io` [ConnectionFactory] with explicit TLS trust overrides.
///
/// This is where the `SecurityContext` / `onBadCertificate` knobs that used to
/// live on `ClientConfig` now reside — keeping `ClientConfig` itself free of
/// `dart:io` types so it can be compiled to the browser. Native callers (the
/// CLI, the test harness) pass the result to `ClientConfig.connectionFactory`.
ConnectionFactory ioConnectionFactory({
  SecurityContext? securityContext,
  bool Function(X509Certificate cert, String host, int port)? onBadCertificate,
  Duration? pingInterval,
}) =>
    (Uri uri, {Map<String, String>? headers}) => FrameConnection.connect(
      uri,
      headers: headers,
      securityContext: securityContext,
      onBadCertificate: onBadCertificate,
      pingInterval: pingInterval,
    );
