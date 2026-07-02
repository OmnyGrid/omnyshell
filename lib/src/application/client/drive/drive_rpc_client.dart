import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../drive/drive_wire.dart';
import '../remote_session.dart';

/// Issues OmnyDrive RPCs over a [SessionMode.drive] [RemoteSession].
///
/// Requests are written as framed [DriveMessage]s on the session's stdin and
/// matched to their replies on stdout by a monotonic correlation id, so several
/// requests may be in flight at once. Inbound bytes immediately replenish the
/// node's send window, keeping large reads flowing under the channel's credit
/// limit.
class DriveRpcClient {
  final RemoteSession _session;
  final DriveFrameReader _reader = DriveFrameReader();
  final Map<int, Completer<DriveMessage>> _pending = {};
  late final StreamSubscription<Uint8List> _sub;
  int _nextId = 1;
  bool _closed = false;

  /// Wraps an already-open drive [session].
  DriveRpcClient(this._session) {
    _sub = _session.stdout.listen(_onData, onDone: _onDone);
    // End every outstanding request if the session exits unexpectedly.
    unawaited(_session.exitCode.then((_) => _onDone()));
  }

  void _onData(Uint8List chunk) {
    if (chunk.isNotEmpty) _session.grantWindow(chunk.length);
    for (final msg in _reader.add(chunk)) {
      final completer = _pending.remove(msg.id);
      if (completer != null && !completer.isCompleted) completer.complete(msg);
    }
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('drive session closed'));
    }
    _pending.clear();
  }

  Future<DriveMessage> _call(
    String op, {
    Map<String, dynamic> fields = const {},
    Uint8List? payload,
    void Function(int sent, int total)? onSent,
  }) {
    if (_closed) throw StateError('drive session is closed');
    final id = _nextId++;
    final completer = Completer<DriveMessage>();
    _pending[id] = completer;
    final frame = DriveMessage.request(
      id,
      op,
      fields: fields,
      payload: payload,
    ).encode();
    // Report progress against the whole on-wire frame (header + payload); the
    // node must receive it all before it acks, so the count reaches the total
    // before the reply future below completes.
    _session.writeStdin(
      frame,
      onFlushed: onSent == null ? null : (sent) => onSent(sent, frame.length),
    );
    return completer.future.then((reply) {
      if (!reply.ok) throw DriveRpcException(reply.error ?? 'drive op failed');
      return reply;
    });
  }

  /// Fetches the served directory manifest as a JSON map. The node returns it as
  /// a (possibly gzipped) UTF-8 JSON payload.
  Future<Map<String, dynamic>> manifest() async {
    final reply = await _call(DriveOp.manifest);
    final json = DriveCompression.decodePayload(reply.header, reply.payload);
    return jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
  }

  /// Reads the bytes of [path] under the served root.
  Future<Uint8List> read(String path) async {
    final reply = await _call(DriveOp.read, fields: {'path': path});
    return Uint8List.fromList(
      DriveCompression.decodePayload(reply.header, reply.payload),
    );
  }

  /// Writes [bytes] to [path] under the served root.
  ///
  /// When [executable] is true the node marks the written file `+x`.
  ///
  /// When [onProgress] is supplied it reports the cumulative on-wire bytes sent
  /// for this write against the frame total, paced by the channel's send window.
  Future<void> write(
    String path,
    List<int> bytes, {
    bool executable = false,
    void Function(int sent, int total)? onProgress,
  }) {
    final (payload, gz) = DriveCompression.encodePayload(path, bytes);
    return _call(
      DriveOp.write,
      fields: {
        'path': path,
        if (gz) kDriveGzipFlag: true,
        if (executable) kDriveExecutable: true,
      },
      payload: payload,
      onSent: onProgress,
    );
  }

  /// Deletes [path] under the served root.
  Future<void> delete(String path) =>
      _call(DriveOp.delete, fields: {'path': path});

  /// Asks the node to copy [from] to [to] under the served root, reusing the
  /// node-side bytes — but only when [from] still hashes to [hash].
  ///
  /// Returns `true` when the node verified and copied; `false` when [from]
  /// drifted or vanished, in which case the caller falls back to a byte
  /// transfer. A `false` outcome is a normal reply, not an error.
  Future<bool> copy(
    String from,
    String to,
    String hash, {
    bool executable = false,
  }) async {
    final reply = await _call(
      DriveOp.copy,
      fields: {
        'from': from,
        'to': to,
        'hash': hash,
        if (executable) kDriveExecutable: true,
      },
    );
    return reply.header['copied'] == true;
  }

  /// Clones [url] into the served root, returning the resulting head SHA and the
  /// checked-out branch.
  Future<({String head, String? branch})> gitClone(
    String url, {
    String? branch,
    int? depth,
    bool bare = false,
  }) async {
    final reply = await _call(
      DriveOp.gitClone,
      fields: {
        'url': url,
        'branch': ?branch,
        'depth': ?depth,
        if (bare) 'bare': true,
      },
    );
    return (
      head: reply.header['head'] as String,
      branch: reply.header['branch'] as String?,
    );
  }

  /// Synchronizes the served git tree in [direction] from [baseline]. Returns
  /// the raw reply header (`head`, `applied`, optional `publishedBranch` /
  /// `conflict`).
  Future<Map<String, dynamic>> gitSync({
    required String url,
    required String direction,
    required String baseline,
    String? mountBranch,
  }) async {
    final reply = await _call(
      DriveOp.gitSync,
      fields: {
        'url': url,
        'direction': direction,
        'baseline': baseline,
        'mountBranch': ?mountBranch,
      },
    );
    return reply.header;
  }

  /// Returns the current git head SHA of the served root.
  Future<String> gitHead() async =>
      (await _call(DriveOp.gitHead)).header['head'] as String;

  /// Closes the session and fails any in-flight requests.
  Future<void> close() async {
    _onDone();
    await _sub.cancel();
    await _session.close();
  }
}

/// Raised when a drive RPC returns an error response.
class DriveRpcException implements Exception {
  /// The error message reported by the node.
  final String message;

  /// Creates a drive RPC exception.
  DriveRpcException(this.message);

  @override
  String toString() => 'DriveRpcException: $message';
}
