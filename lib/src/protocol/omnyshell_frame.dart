import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'control_message.dart';
import 'data_opcode.dart';
import 'protocol_version.dart';

/// A decoded unit travelling over a connection: either a structured control
/// message ([ControlFrame]) or a binary stream payload ([DataFrame]).
///
/// `FrameCodec` converts raw WebSocket events (text → control, binary → data)
/// to and from this sealed type, so connection code handles a single stream of
/// [OmnyShellFrame]s.
@immutable
sealed class OmnyShellFrame {
  /// Base constructor.
  const OmnyShellFrame();

  /// The channel this frame belongs to (`null`/`0` for connection control).
  int? get channelId;
}

/// A control message frame (carried as a WebSocket text frame).
@immutable
final class ControlFrame extends OmnyShellFrame {
  /// The wrapped control message.
  final ControlMessage message;

  /// Wraps [message] as a frame.
  const ControlFrame(this.message);

  @override
  int? get channelId => message.channelId;
}

/// A binary stream-data frame (carried as a WebSocket binary frame) with a
/// fixed 10-byte header followed by the raw payload bytes.
@immutable
final class DataFrame extends OmnyShellFrame {
  /// The protocol version byte.
  final int version;

  /// Which stream the payload belongs to.
  final DataOpcode opcode;

  /// The channel id (uint32).
  final int channel;

  /// The raw stream bytes.
  final Uint8List payload;

  /// Creates a data frame, defaulting [version] to the current protocol.
  DataFrame({
    required this.opcode,
    required this.channel,
    required this.payload,
    this.version = kProtocolVersion,
  });

  @override
  int? get channelId => channel;
}
