/// The wire protocol version implemented by this package.
///
/// Sent in `hello` and stamped into every binary data-frame header. Peers
/// negotiate compatibility on connect; a mismatch fails the handshake.
const int kProtocolVersion = 1;

/// The lowest protocol version this build can interoperate with.
const int kMinProtocolVersion = 1;

/// Whether a peer advertising [remoteVersion] (with optional [remoteMin]) is
/// compatible with this build.
bool isProtocolCompatible(int remoteVersion, {int? remoteMin}) {
  final theirMin = remoteMin ?? remoteVersion;
  return remoteVersion >= kMinProtocolVersion && theirMin <= kProtocolVersion;
}
