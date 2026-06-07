import '../../shared/errors/omnyshell_exception.dart';
import '../../shared/utils/bytes.dart';

/// A logical channel identifier, scoped to a single physical connection.
///
/// Channels multiplex independent streams (sessions, future tunnels) over one
/// connection, SSH-style. The value is a `uint32`; `0` is reserved for
/// connection-level control and is not a valid session channel.
class ChannelId {
  /// The numeric channel id (`0..0xFFFFFFFF`).
  final int value;

  /// Wraps a channel id [value].
  ///
  /// Throws [ProtocolException] if [value] is outside the `uint32` range.
  factory ChannelId(int value) {
    if (value < 0 || value > Bytes.maxUint32) {
      throw ProtocolException('Channel id out of range: $value');
    }
    return ChannelId._(value);
  }

  const ChannelId._(this.value);

  /// The reserved connection-control channel (`0`).
  static const ChannelId control = ChannelId._(0);

  /// Whether this is the reserved control channel.
  bool get isControl => value == 0;

  @override
  bool operator ==(Object other) => other is ChannelId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'channel#$value';
}
