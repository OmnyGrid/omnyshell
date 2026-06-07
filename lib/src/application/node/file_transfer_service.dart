import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../protocol/channel.dart';
import '../../protocol/control_message.dart';
import '../../shared/utils/clock.dart';
import '../transfer/transfer_engine.dart';

/// A [TransferLink] backed by a node-side [Channel].
///
/// The node always reads requests/data on the channel's stdin and writes
/// manifests/data on stdout, granting stdin credit as it consumes (flow
/// control), regardless of transfer direction.
class ChannelTransferLink implements TransferLink {
  final Channel _channel;

  /// Wraps [_channel].
  ChannelTransferLink(this._channel);

  @override
  Stream<Uint8List> get inbound => _channel.stdin;

  @override
  void send(List<int> bytes) => _channel.sendStdout(bytes);

  @override
  void grantWindow(int credit) => _channel.sendControl(
    ChannelWindow(channel: _channel.id, stream: 'stdin', credit: credit),
  );

  @override
  int get queuedBytes => _channel.queuedBytes;
}

/// Serves one transfer-mode session on the node: builds/consumes the file
/// payload over [channel] using a [FileTransferEngine], then signals completion
/// with the usual `channel.exit`/`channel.close`.
///
/// The request parameters ride the standard session fields: `command` is the
/// direction (`download`/`upload`), `args.first` is the remote path, and
/// `env['gzipLevel']` is the compression level.
class FileTransferService {
  /// The adopted node-side channel.
  final Channel channel;

  /// The session-open request describing the transfer.
  final NodeSessionOpen request;

  /// The clock used for the exit timestamp.
  final Clock clock;

  /// Diagnostic logger.
  final void Function(String message)? log;

  /// Called after the transfer ends so the runtime can forget the channel.
  final Future<void> Function() onClose;

  StreamSubscription<ControlMessage>? _controlSub;

  /// Creates a transfer service.
  FileTransferService({
    required this.channel,
    required this.request,
    required this.onClose,
    this.clock = const SystemClock(),
    this.log,
  });

  /// Runs the transfer to completion.
  Future<void> run() async {
    // If the client tears down early, close the channel so the engine's reader
    // observes end-of-stream and unwinds.
    _controlSub = channel.control.listen((m) {
      if (m is ChannelClose) unawaited(channel.close());
    });

    final direction = request.command ?? 'download';
    final remotePath = request.args.isEmpty ? '.' : request.args.first;
    final level =
        int.tryParse(request.env['gzipLevel'] ?? '') ?? kDefaultGzipLevel;
    final link = ChannelTransferLink(channel);
    final engine = FileTransferEngine(link);

    var exitCode = 0;
    try {
      if (direction == 'download') {
        final m = buildManifest(remotePath);
        await engine.runSender(
          baseDir: m.baseDir,
          entries: m.entries,
          single: m.single,
          gzipLevel: level,
        );
      } else {
        final result = await engine.runReceiver(
          dest: remotePath,
          destIsDir:
              remotePath.endsWith('/') ||
              remotePath.endsWith(Platform.pathSeparator),
        );
        if (!result.ok) exitCode = 1;
      }
    } on Object catch (e) {
      log?.call('[transfer] $direction failed: $e');
      exitCode = 1;
      _sendError('$e');
    }

    channel.sendControl(
      ChannelExit(channel: channel.id, exitCode: exitCode, ts: clock.now()),
    );
    channel.sendControl(ChannelClose(channel: channel.id, reason: 'normal'));
    await _controlSub?.cancel();
    await onClose();
  }

  void _sendError(String message) {
    // Best-effort error record (tag 0x07) so a peer mid-protocol learns why.
    final payload = utf8.encode(message);
    final header = Uint8List(5);
    header[0] = 0x07;
    header[1] = (payload.length >> 24) & 0xFF;
    header[2] = (payload.length >> 16) & 0xFF;
    header[3] = (payload.length >> 8) & 0xFF;
    header[4] = payload.length & 0xFF;
    channel.sendStdout(header);
    if (payload.isNotEmpty) channel.sendStdout(payload);
  }
}
