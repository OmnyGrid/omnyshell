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
  }) {
    if (_closed) throw StateError('drive session is closed');
    final id = _nextId++;
    final completer = Completer<DriveMessage>();
    _pending[id] = completer;
    _session.writeStdin(
      DriveMessage.request(id, op, fields: fields, payload: payload).encode(),
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
  Future<void> write(String path, List<int> bytes) {
    final (payload, gz) = DriveCompression.encodePayload(path, bytes);
    return _call(
      DriveOp.write,
      fields: {'path': path, if (gz) kDriveGzipFlag: true},
      payload: payload,
    );
  }

  /// Deletes [path] under the served root.
  Future<void> delete(String path) =>
      _call(DriveOp.delete, fields: {'path': path});

  /// Clones [url] into the served root, returning the resulting head SHA.
  Future<String> gitClone(
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
    return reply.header['head'] as String;
  }

  /// Synchronizes the served git tree in [direction] from [baseline]. Returns
  /// the raw reply header (`head`, `applied`, optional `publishedBranch` /
  /// `conflict`).
  Future<Map<String, dynamic>> gitSync({
    required String url,
    required String direction,
    required String baseline,
  }) async {
    final reply = await _call(
      DriveOp.gitSync,
      fields: {'url': url, 'direction': direction, 'baseline': baseline},
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
