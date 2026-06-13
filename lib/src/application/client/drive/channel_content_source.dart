import 'package:omnydrive/omnydrive.dart' hide Clock, SystemClock;

import 'drive_rpc_client.dart';

/// An OmnyDrive [ContentSource] backed by a node-side path reached over a drive
/// session.
///
/// Each operation becomes a [DriveRpcClient] call: the node executes it against
/// its local filesystem and streams back the result. This lets OmnyDrive's
/// directory synchronizer treat a remote node path exactly like a local one,
/// with no transport-specific logic in the engine.
class ChannelContentSource implements ContentSource {
  final DriveRpcClient _rpc;

  @override
  final bool isWritable;

  /// Wraps [rpc]; [isWritable] reflects the mount's access mode (the node also
  /// enforces it).
  ChannelContentSource(this._rpc, {this.isWritable = false});

  @override
  Future<FileManifest> manifest() async =>
      FileManifest.fromJson(await _rpc.manifest());

  @override
  Future<List<int>> readBytes(String relativePath) => _rpc.read(relativePath);

  @override
  Future<void> writeBytes(
    String relativePath,
    List<int> bytes, {
    bool executable = false,
    void Function(int sent, int total)? onProgress,
  }) => _rpc.write(
    relativePath,
    bytes,
    executable: executable,
    onProgress: onProgress,
  );

  @override
  Future<void> delete(String relativePath) => _rpc.delete(relativePath);

  @override
  Future<bool> supportsCopy() async => isWritable;

  @override
  Future<bool> copy(
    String fromPath,
    String toPath,
    ContentHash expectedHash, {
    bool executable = false,
  }) => _rpc.copy(fromPath, toPath, expectedHash.value, executable: executable);
}
