import 'dart:typed_data';

import '../../domain/entities/session.dart';
import '../transfer/transfer_engine.dart';
import 'client_runtime.dart';
import 'remote_session.dart';

/// A [TransferLink] backed by a client-side [RemoteSession].
///
/// The client always sends on stdin and receives on stdout, granting stdout
/// credit as it consumes (flow control), regardless of transfer direction.
class ClientTransferLink implements TransferLink {
  final RemoteSession _session;

  /// Wraps [_session].
  ClientTransferLink(this._session);

  @override
  Stream<Uint8List> get inbound => _session.stdout;

  @override
  void send(List<int> bytes) => _session.writeStdin(bytes);

  @override
  void grantWindow(int credit) => _session.grantWindow(credit);

  @override
  int get queuedBytes => _session.queuedBytes;
}

/// Opens a transfer session of [direction] on [nodeId] over [client] (which
/// should be a dedicated, parallel Hub connection).
Future<RemoteSession> _openTransfer(
  ClientRuntime client, {
  required String nodeId,
  required String direction,
  required String remotePath,
  required int gzipLevel,
}) => client.openSession(
  nodeId: nodeId,
  mode: SessionMode.transfer,
  command: direction,
  args: [remotePath],
  env: {'gzipLevel': '$gzipLevel'},
);

/// Downloads [remotePath] from [nodeId] to the local [localDest] (a directory to
/// write into, or an explicit target path — see [FileTransferEngine.runReceiver];
/// [destIsDir] forces directory mode), resuming any partial files and verifying
/// each file's SHA-256.
Future<TransferResult> downloadPath({
  required ClientRuntime client,
  required String nodeId,
  required String remotePath,
  required String localDest,
  bool destIsDir = false,
  int gzipLevel = kDefaultGzipLevel,
  void Function(TransferProgress)? onProgress,
  Future<bool> Function(TransferPreflight)? confirm,
}) async {
  final session = await _openTransfer(
    client,
    nodeId: nodeId,
    direction: 'download',
    remotePath: remotePath,
    gzipLevel: gzipLevel,
  );
  try {
    final engine = FileTransferEngine(ClientTransferLink(session));
    final result = await engine.runReceiver(
      dest: localDest,
      destIsDir: destIsDir,
      onProgress: onProgress,
      confirm: confirm,
    );
    await session.exitCode;
    return result;
  } finally {
    await session.close();
  }
}

/// Uploads the local [localPath] to [remoteDir] on [nodeId], resuming any
/// partial files; the node verifies each file's SHA-256 and reports failure via
/// the session exit code.
Future<TransferResult> uploadPath({
  required ClientRuntime client,
  required String nodeId,
  required String localPath,
  required String remoteDir,
  int gzipLevel = kDefaultGzipLevel,
  void Function(TransferProgress)? onProgress,
  Future<bool> Function(TransferPreflight)? confirm,
}) async {
  final manifest = buildManifest(localPath);
  final session = await _openTransfer(
    client,
    nodeId: nodeId,
    direction: 'upload',
    remotePath: remoteDir,
    gzipLevel: gzipLevel,
  );
  try {
    final engine = FileTransferEngine(ClientTransferLink(session));
    await engine.runSender(
      baseDir: manifest.baseDir,
      entries: manifest.entries,
      single: manifest.single,
      gzipLevel: gzipLevel,
      onProgress: onProgress,
      confirm: confirm,
    );
    final code = await session.exitCode;
    if (code == 0) {
      return TransferResult(
        verified: [for (final e in manifest.entries) e.path],
        failures: const {},
      );
    }
    return TransferResult(
      verified: const [],
      failures: {
        for (final e in manifest.entries) e.path: 'node reported a failure',
      },
    );
  } finally {
    await session.close();
  }
}
