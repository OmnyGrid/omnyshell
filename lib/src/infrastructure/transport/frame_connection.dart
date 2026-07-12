import 'dart:io';

import 'package:omnyhub/omnyhub.dart' as omnyhub;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../protocol/frame_codec.dart';
import '../../protocol/omnyshell_connection.dart';
import '../../protocol/omnyshell_frame.dart';

/// Bridges OmnyShell's [FrameCodec] to omnyhub's raw [omnyhub.Message] model, so
/// OmnyShell frames ride on omnyhub's transport.
class _FrameConnectionCodec implements omnyhub.ConnectionCodec<OmnyShellFrame> {
  final FrameCodec codec;

  _FrameConnectionCodec(this.codec);

  @override
  omnyhub.Message encode(OmnyShellFrame frame) {
    final encoded = codec.encode(frame); // String (control) or Uint8List (data)
    return encoded is String
        ? omnyhub.TextMessage(encoded)
        : omnyhub.BinaryMessage(encoded as List<int>);
  }

  @override
  OmnyShellFrame decode(omnyhub.Message message) => switch (message) {
    omnyhub.TextMessage(:final data) => codec.decode(data),
    omnyhub.BinaryMessage(:final data) => codec.decode(data),
  };
}

/// An [OmnyShellConnection] backed by an omnyhub [omnyhub.Connection] (WebSocket
/// on the VM), applying [FrameCodec] at the boundary via omnyhub's
/// [omnyhub.TypedConnection].
///
/// This replaces OmnyShell's hand-written `dart:io` WebSocket adapter: the
/// listener wraps each accepted omnyhub connection with [FrameConnection.fromChannel],
/// and clients dial with [FrameConnection.connect]. Undecodable frames are
/// dropped (never tearing the connection down), and text↔control /
/// binary↔data mapping is preserved.
class FrameConnection implements OmnyShellConnection {
  final omnyhub.TypedConnection<OmnyShellFrame> _typed;

  FrameConnection._(this._typed);

  /// Wraps an omnyhub [connection], applying [codec] (defaults to the standard
  /// registry).
  factory FrameConnection.wrap(
    omnyhub.Connection connection, {
    FrameCodec? codec,
  }) => FrameConnection._(
    omnyhub.TypedConnection<OmnyShellFrame>(
      connection,
      _FrameConnectionCodec(codec ?? FrameCodec.standard()),
    ),
  );

  /// Wraps an already-upgraded WebSocket [channel] (Hub server side).
  factory FrameConnection.fromChannel(
    WebSocketChannel channel, {
    FrameCodec? codec,
  }) => FrameConnection.wrap(
    omnyhub.WebSocketConnection.fromChannel(channel),
    codec: codec,
  );

  /// Dials [uri] (a `wss://`/`ws://` URL) and returns a connected
  /// [FrameConnection] (client / node side).
  static Future<FrameConnection> connect(
    Uri uri, {
    Map<String, dynamic>? headers,
    FrameCodec? codec,
    SecurityContext? securityContext,
    Duration? pingInterval,
    bool Function(X509Certificate cert, String host, int port)?
    onBadCertificate,
  }) async {
    final connection = await omnyhub.WebSocketConnection.connect(
      uri,
      headers: headers,
      securityContext: securityContext,
      pingInterval: pingInterval,
      onBadCertificate: onBadCertificate,
    );
    return FrameConnection.wrap(connection, codec: codec);
  }

  @override
  Stream<OmnyShellFrame> get incoming => _typed.incoming;

  @override
  bool get isOpen => _typed.isOpen;

  @override
  Future<void> get done => _typed.done;

  @override
  void send(OmnyShellFrame frame) => _typed.send(frame);

  @override
  Future<void> close([int? code, String? reason]) => _typed.close(code, reason);
}
