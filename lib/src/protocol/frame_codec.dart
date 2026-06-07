import 'dart:convert';
import 'dart:typed_data';

import '../shared/errors/error_codes.dart';
import '../shared/errors/omnyshell_exception.dart';
import '../shared/utils/bytes.dart';
import 'control_message.dart';
import 'data_opcode.dart';
import 'omnyshell_frame.dart';

/// Decodes a control-message payload (the envelope `d`) for a registered type.
///
/// Receives the channel id from the envelope `c` and the payload map `d`.
typedef ControlDecoder =
    ControlMessage Function(int? channelId, Map<String, dynamic> data);

/// Encodes and decodes [OmnyShellFrame]s to and from WebSocket events.
///
/// Control messages map to JSON text frames `{"t":..,"c":..,"d":..}`; stream
/// data maps to binary frames with a fixed 10-byte header (version, opcode,
/// channel id, payload length) followed by the raw bytes. The control decoder
/// set is extensible via [register], so third-party packages can add message
/// types over the same transport.
class FrameCodec {
  /// The fixed binary data-frame header size, in bytes.
  static const int headerSize = 10;

  /// The maximum payload a single data frame may carry (64 KiB). Senders split
  /// larger writes; receivers reject anything larger as malformed.
  static const int maxDataPayload = 64 * 1024;

  final Map<String, ControlDecoder> _decoders;

  FrameCodec._(this._decoders);

  /// Creates a codec pre-registered with all built-in control messages.
  factory FrameCodec.standard() => FrameCodec._(Map.of(_builtIn));

  /// The control types this codec can decode.
  Iterable<String> get registeredTypes => _decoders.keys;

  /// Registers a [decoder] for a custom control message [type].
  ///
  /// Throws [ArgumentError] if [type] is already registered.
  void register(String type, ControlDecoder decoder) {
    if (_decoders.containsKey(type)) {
      throw ArgumentError.value(type, 'type', 'already registered');
    }
    _decoders[type] = decoder;
  }

  // --- Unified WebSocket event encode/decode --------------------------------

  /// Encodes [frame] into the value to add to a WebSocket sink: a [String] for
  /// control frames or a [Uint8List] for data frames.
  Object encode(OmnyShellFrame frame) => switch (frame) {
    ControlFrame(message: final m) => encodeControl(m),
    final DataFrame f => encodeData(f),
  };

  /// Decodes a raw WebSocket [event] (a [String] text frame or `List<int>`
  /// binary frame) into an [OmnyShellFrame].
  ///
  /// Throws [ProtocolException] on malformed input.
  OmnyShellFrame decode(Object event) {
    if (event is String) return decodeControl(event);
    if (event is List<int>) return decodeData(event);
    throw const ProtocolException('Unsupported WebSocket frame type');
  }

  // --- Control frames -------------------------------------------------------

  /// Encodes a control [message] into a JSON envelope string.
  String encodeControl(ControlMessage message) {
    final channel = message.channelId;
    final envelope = <String, dynamic>{
      't': message.type,
      'd': message.toJson(),
    };
    if (channel != null) envelope['c'] = channel;
    return jsonEncode(envelope);
  }

  /// Decodes a JSON envelope [text] into a [ControlFrame].
  ControlFrame decodeControl(String text) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } on FormatException catch (e) {
      throw ProtocolException('Invalid control JSON: ${e.message}');
    }
    if (raw is! Map) {
      throw const ProtocolException('Control frame must be a JSON object');
    }
    final map = raw.cast<String, dynamic>();
    final type = map['t'];
    if (type is! String) {
      throw const ProtocolException("Control frame missing 't'");
    }
    final decoder = _decoders[type];
    if (decoder == null) {
      throw ProtocolException('Unknown control message type: $type');
    }
    final channel = map['c'] is int ? map['c'] as int : null;
    final data = map['d'] is Map
        ? (map['d'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    return ControlFrame(decoder(channel, data));
  }

  // --- Data frames ----------------------------------------------------------

  /// Encodes a [frame] into its 10-byte header + payload bytes.
  ///
  /// Throws [ProtocolException] if the payload exceeds [maxDataPayload].
  Uint8List encodeData(DataFrame frame) {
    final payload = frame.payload;
    if (payload.length > maxDataPayload) {
      throw ProtocolException(
        'Data payload ${payload.length} exceeds max $maxDataPayload',
        code: ErrorCodes.malformedFrame,
      );
    }
    final out = Uint8List(headerSize + payload.length);
    out[0] = frame.version & 0xFF;
    out[1] = frame.opcode.wire & 0xFF;
    Bytes.writeUint32(out, 2, frame.channel);
    Bytes.writeUint32(out, 6, payload.length);
    out.setRange(headerSize, out.length, payload);
    return out;
  }

  /// Decodes [bytes] (header + payload) into a [DataFrame].
  ///
  /// Throws [ProtocolException] ([ErrorCodes.malformedFrame]) if the header is
  /// truncated, the declared length disagrees with the frame, or the payload
  /// exceeds [maxDataPayload].
  DataFrame decodeData(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data.length < headerSize) {
      throw const ProtocolException(
        'Data frame shorter than header',
        code: ErrorCodes.malformedFrame,
      );
    }
    final version = data[0];
    final opcode = DataOpcode.fromWire(data[1]);
    final channel = Bytes.readUint32(data, 2);
    final declaredLen = Bytes.readUint32(data, 6);
    final actualLen = data.length - headerSize;
    if (declaredLen != actualLen) {
      throw ProtocolException(
        'Data frame length mismatch: declared $declaredLen, got $actualLen',
        code: ErrorCodes.malformedFrame,
      );
    }
    if (actualLen > maxDataPayload) {
      throw ProtocolException(
        'Data payload $actualLen exceeds max $maxDataPayload',
        code: ErrorCodes.malformedFrame,
      );
    }
    return DataFrame(
      version: version,
      opcode: opcode,
      channel: channel,
      payload: Uint8List.sublistView(data, headerSize),
    );
  }

  static final Map<String, ControlDecoder> _builtIn = {
    Hello.typeName: Hello.fromJson,
    AuthRequest.typeName: AuthRequest.fromJson,
    AuthOk.typeName: AuthOk.fromJson,
    AuthFail.typeName: AuthFail.fromJson,
    NodeRegister.typeName: NodeRegister.fromJson,
    NodeRegistered.typeName: NodeRegistered.fromJson,
    NodeCapabilitiesMessage.typeName: NodeCapabilitiesMessage.fromJson,
    NodeHeartbeat.typeName: NodeHeartbeat.fromJson,
    NodeHeartbeatAck.typeName: NodeHeartbeatAck.fromJson,
    Ping.typeName: Ping.fromJson,
    Pong.typeName: Pong.fromJson,
    NodeListRequest.typeName: NodeListRequest.fromJson,
    NodeListResponse.typeName: NodeListResponse.fromJson,
    SessionOpen.typeName: SessionOpen.fromJson,
    SessionOpened.typeName: SessionOpened.fromJson,
    SessionRejected.typeName: SessionRejected.fromJson,
    NodeSessionOpen.typeName: NodeSessionOpen.fromJson,
    NodeSessionOpened.typeName: NodeSessionOpened.fromJson,
    NodeSessionRejected.typeName: NodeSessionRejected.fromJson,
    ChannelResize.typeName: ChannelResize.fromJson,
    ChannelSignal.typeName: ChannelSignal.fromJson,
    ChannelEof.typeName: ChannelEof.fromJson,
    ChannelExit.typeName: ChannelExit.fromJson,
    ChannelClose.typeName: ChannelClose.fromJson,
    ChannelWindow.typeName: ChannelWindow.fromJson,
    ProtocolError.typeName: ProtocolError.fromJson,
  };
}
