import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnydrive/omnydrive.dart' hide Clock, SystemClock;

import '../../infrastructure/backend/shell_invocation.dart';
import '../../protocol/channel.dart';
import '../../protocol/control_message.dart';
import '../../shared/utils/clock.dart';
import '../../shared/utils/omnyshell_home.dart';
import '../drive/drive_wire.dart';

/// Serves one OmnyDrive mount on the node ([SessionMode.drive]).
///
/// The node is the passive side of a mount: it exposes a path as a
/// [ContentSource] (for `dir` drives) or a git working tree (for `git` drives)
/// and answers the client's content/sync RPCs. The client runs the OmnyDrive
/// sync engine and decides what to read, write or commit.
///
/// Requests arrive as framed [DriveMessage]s on the channel's stdin and replies
/// go back on stdout. The served root and access mode ride the session-open
/// fields: `command` is the served path, `env` carries [DriveEnv.kind] and
/// [DriveEnv.readWrite]. Requests are processed one at a time so concurrent
/// filesystem effects stay ordered.
class NodeDriveService {
  /// The adopted node-side channel.
  final Channel channel;

  /// The session-open request describing the mount.
  final NodeSessionOpen request;

  /// A stable endpoint id for this node, used to scope git drive ids.
  final String endpointId;

  /// The clock used for timestamps.
  final Clock clock;

  /// Diagnostic logger.
  final void Function(String message)? log;

  /// Called once the session ends so the runtime can forget the channel.
  final Future<void> Function() onClose;

  /// The git CLI used for git-drive operations. Injectable for testing.
  final GitCli git;

  /// Resolves the git credential (if any) for a private remote, keyed by host.
  /// Null (or a null resolution) means git falls back to the node host's own
  /// configuration. Credentials live only on the node and are never sent to the
  /// hub, peers, or serialized onto a [Drive].
  final GitCredentialResolver? gitCredentials;

  final DriveFrameReader _reader = DriveFrameReader();
  final _done = Completer<void>();
  Future<void> _chain = Future.value();
  StreamSubscription<Uint8List>? _stdinSub;
  StreamSubscription<ControlMessage>? _controlSub;

  late final String _root;
  late final bool _readWrite;
  late final String _kind;
  late final PathFilter _filter;

  // Git state, populated by the first git.clone (or git.sync after a remount).
  Drive? _gitDrive;

  /// Creates a drive service.
  NodeDriveService({
    required this.channel,
    required this.request,
    required this.endpointId,
    required this.onClose,
    this.clock = const SystemClock(),
    this.log,
    this.git = const GitCli(),
    this.gitCredentials,
  });

  /// Serves the mount until the channel closes.
  Future<void> run() async {
    _root = resolveRoot(request.command, isWindows: Platform.isWindows);
    _readWrite = request.env[DriveEnv.readWrite] == '1';
    _kind = request.env[DriveEnv.kind] ?? DriveEnv.kindDir;
    _filter = _parseFilter(request.env[DriveEnv.filter]);

    // Directory drives serve an existing tree; create the root so an empty
    // initial mount has somewhere to receive the first push.
    if (_kind == DriveEnv.kindDir) {
      try {
        await Directory(_root).create(recursive: true);
      } on Object catch (e) {
        log?.call('[drive] cannot create root $_root: $e');
      }
    }

    _stdinSub = channel.stdin.listen(
      _onData,
      onDone: _finish,
      cancelOnError: false,
    );
    _controlSub = channel.control.listen((m) {
      if (m is ChannelClose) _finish();
    });

    await _done.future;
    await _stdinSub?.cancel();
    await _controlSub?.cancel();
    await onClose();
  }

  void _onData(Uint8List chunk) {
    // Replenish the client's send window as we consume its bytes.
    if (chunk.isNotEmpty) {
      channel.sendControl(
        ChannelWindow(
          channel: channel.id,
          stream: 'stdin',
          credit: chunk.length,
        ),
      );
    }
    for (final msg in _reader.add(chunk)) {
      // Serialize handling so filesystem/git effects apply in request order.
      _chain = _chain.then((_) => _handle(msg));
    }
  }

  Future<void> _handle(DriveMessage msg) async {
    final id = msg.id;
    try {
      switch (msg.op) {
        case DriveOp.manifest:
          final manifest = await _content(writable: false).manifest();
          final json = utf8.encode(jsonEncode(manifest.toJson()));
          final (payload, gz) = DriveCompression.encodePayload(null, json);
          _reply(
            DriveMessage.ok(
              id,
              fields: {if (gz) kDriveGzipFlag: true},
              payload: payload,
            ),
          );
        case DriveOp.read:
          final path = msg.header['path'] as String;
          final bytes = await _content(writable: false).readBytes(path);
          final (payload, gz) = DriveCompression.encodePayload(path, bytes);
          _reply(
            DriveMessage.ok(
              id,
              fields: {if (gz) kDriveGzipFlag: true},
              payload: payload,
            ),
          );
        case DriveOp.write:
          final bytes = DriveCompression.decodePayload(msg.header, msg.payload);
          await _content(writable: true).writeBytes(
            msg.header['path'] as String,
            bytes,
            executable: msg.header[kDriveExecutable] == true,
          );
          _reply(DriveMessage.ok(id));
        case DriveOp.delete:
          await _content(writable: true).delete(msg.header['path'] as String);
          _reply(DriveMessage.ok(id));
        case DriveOp.copy:
          final copied = await _content(writable: true).copy(
            msg.header['from'] as String,
            msg.header['to'] as String,
            ContentHash.parse(msg.header['hash'] as String),
            executable: msg.header[kDriveExecutable] == true,
          );
          _reply(DriveMessage.ok(id, fields: {'copied': copied}));
        case DriveOp.gitClone:
          _reply(await _gitClone(id, msg.header));
        case DriveOp.gitSync:
          _reply(await _gitSync(id, msg.header));
        case DriveOp.gitHead:
          final head = await git.revParse(_root);
          _reply(DriveMessage.ok(id, fields: {'head': head}));
        default:
          _reply(DriveMessage.err(id, 'unknown op: ${msg.op}'));
      }
    } on Object catch (e) {
      log?.call('[drive] op ${msg.op} failed: $e');
      _reply(DriveMessage.err(id, '$e'));
    }
  }

  // The client owns the mount and drives sync direction, so it may always write
  // the node mirror (a read-only mount simply means the client never pulls node
  // edits back — it does not block the client populating the mirror).
  LocalContentSource _content({required bool writable}) => LocalContentSource(
    _root,
    isWritable: writable,
    filter: _filter.isEmpty ? null : _filter,
  );

  /// Resolves the served mount root from the client-supplied [command].
  ///
  /// Expands a leading `~` against the node user's home, then — on Windows —
  /// translates an MSYS mount root (`/c/Users/x`, the Git Bash form a client may
  /// send) into a Windows path (`C:\Users\x`). Without the translation `dart:io`
  /// treats `/c/...` as relative to the current drive and creates `C:\c\Users\x`.
  ///
  /// Pure and platform-parameterized (via [isWindows]) so the Windows branch is
  /// unit-testable off Windows. Returns a single value assigned once to [_root]
  /// — it must not be called more than once per service since [_root] is `final`.
  static String resolveRoot(String? command, {required bool isWindows}) {
    final root = expandUserHome(command ?? '.');
    if (isWindows && root.startsWith('/')) {
      return windowsPathFromMsys(root);
    }
    return root;
  }

  /// Decodes the session's [DriveEnv.filter] JSON, defaulting to an empty
  /// (everything-passes) filter when absent or malformed.
  PathFilter _parseFilter(String? raw) {
    if (raw == null || raw.isEmpty) return PathFilter.empty;
    try {
      return PathFilter.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object catch (e) {
      log?.call('[drive] ignoring invalid filter: $e');
      return PathFilter.empty;
    }
  }

  Future<DriveMessage> _gitClone(int id, Map<String, dynamic> h) async {
    final url = h['url'] as String;
    final origin = OriginUri(url);
    final credential = gitCredentials?.resolve(origin);
    // A populated, non-empty destination means a prior clone — reuse it.
    final dir = Directory(_root);
    final exists = await dir.exists() && !(await dir.list().isEmpty);
    if (!exists) {
      await git.clone(
        origin.scheme == OriginUriScheme.file
            ? Uri.parse(url).toFilePath()
            : url,
        _root,
        branch: h['branch'] as String?,
        depth: (h['depth'] as num?)?.toInt(),
        bare: h['bare'] == true,
        credential: credential,
      );
    }
    _gitDrive =
        await GitProvider(
          endpoint: EndpointId(endpointId),
          credentials: gitCredentials,
        ).describe(
          origin,
          accessMode: _readWrite ? AccessMode.readWrite : AccessMode.readOnly,
        );
    final head = await git.revParse(_root);
    return DriveMessage.ok(id, fields: {'head': head});
  }

  Future<DriveMessage> _gitSync(int id, Map<String, dynamic> h) async {
    final drive = _gitDrive ??=
        await GitProvider(
          endpoint: EndpointId(endpointId),
          credentials: gitCredentials,
        ).describe(
          OriginUri(h['url'] as String),
          accessMode: _readWrite ? AccessMode.readWrite : AccessMode.readOnly,
        );
    final direction = (h['direction'] as String) == 'push'
        ? SyncDirection.push
        : SyncDirection.pull;
    final baseline = SyncRef.git(h['baseline'] as String);
    final mount = MountInfo(
      id: MountId('mount'),
      driveId: drive.id,
      localPath: LocalPath(_root),
      accessMode: drive.accessMode,
      mountType: MountType.mirror,
      mountedAt: clock.now(),
      syncState: SyncState(baselineRef: baseline),
    );
    final sync = GitProvider(
      endpoint: EndpointId(endpointId),
      credentials: gitCredentials,
    ).synchronizer(drive);
    try {
      final plan = await sync.plan(
        mount: mount,
        baseline: baseline,
        direction: direction,
      );
      final result = await sync.apply(
        mount: mount,
        plan: plan,
        baseline: baseline,
      );
      return DriveMessage.ok(
        id,
        fields: {
          'head': result.newRef.value,
          'applied': result.appliedChanges,
          if (result.publishedBranch != null)
            'publishedBranch': result.publishedBranch,
        },
      );
    } on ConflictDetectedException catch (e) {
      return DriveMessage.ok(
        id,
        fields: {
          'conflict': {
            'expected': e.conflict.expectedRef.value,
            'actual': e.conflict.actualRef?.value,
            'message': e.conflict.message,
          },
        },
      );
    }
  }

  void _reply(DriveMessage msg) {
    if (!channel.closed) channel.sendStdout(msg.encode());
  }

  void _finish() {
    if (_done.isCompleted) return;
    channel.sendControl(
      ChannelExit(channel: channel.id, exitCode: 0, ts: clock.now()),
    );
    channel.sendControl(ChannelClose(channel: channel.id, reason: 'normal'));
    _done.complete();
  }
}
