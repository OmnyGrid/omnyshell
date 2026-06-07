import 'error_codes.dart';

/// Base type for every expected, classified failure raised by OmnyShell.
///
/// Each exception carries a stable [code] (see [ErrorCodes]) and a
/// human-readable [message]. The hierarchy is `sealed` so callers can
/// exhaustively switch on the failure kind, and so the protocol layer can map
/// between exceptions and `error` control messages without a catch-all.
sealed class OmnyShellException implements Exception {
  /// A stable, machine-readable error code.
  final String code;

  /// A human-readable description of the failure.
  final String message;

  /// Creates an exception with [code] and [message].
  const OmnyShellException(this.code, this.message);

  @override
  String toString() => '$runtimeType($code): $message';
}

/// A frame could not be decoded, or a message violated the protocol.
class ProtocolException extends OmnyShellException {
  /// Creates a protocol exception.
  const ProtocolException(String message, {String? code})
    : super(code ?? ErrorCodes.protocolError, message);
}

/// Authentication failed: credentials missing, malformed or rejected.
class AuthException extends OmnyShellException {
  /// Creates an authentication exception.
  const AuthException(String message) : super(ErrorCodes.authFailed, message);
}

/// The authenticated principal is not permitted to perform the action.
class AuthorizationException extends OmnyShellException {
  /// Creates an authorization exception.
  const AuthorizationException(String message)
    : super(ErrorCodes.notAuthorized, message);
}

/// The requested node is unknown or offline.
class NodeUnavailableException extends OmnyShellException {
  /// Creates a node-unavailable exception with an explicit [code]
  /// ([ErrorCodes.unknownNode] or [ErrorCodes.nodeOffline]).
  const NodeUnavailableException(super.code, super.message);
}

/// A session could not be opened (rejected by the Hub or node).
class SessionRejectedException extends OmnyShellException {
  /// Creates a session-rejected exception.
  const SessionRejectedException(String message, {String? code})
    : super(code ?? ErrorCodes.sessionRejected, message);
}

/// A logical channel was closed or referenced after teardown.
class ChannelException extends OmnyShellException {
  /// Creates a channel exception.
  const ChannelException(String message, {String? code})
    : super(code ?? ErrorCodes.unknownChannel, message);
}

/// The underlying transport failed or closed unexpectedly.
class TransportException extends OmnyShellException {
  /// Creates a transport exception.
  const TransportException(String message)
    : super(ErrorCodes.transportError, message);
}

/// An operation exceeded its deadline.
class OmnyShellTimeoutException extends OmnyShellException {
  /// Creates a timeout exception.
  const OmnyShellTimeoutException(String message)
    : super(ErrorCodes.timeout, message);
}
