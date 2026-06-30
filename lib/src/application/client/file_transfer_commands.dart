import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnydrive/omnydrive.dart'
    show PathFilter, ProgressEvent, SyncDirection;

import '../../shared/utils/progress_bar.dart';
import '../transfer/transfer_engine.dart';
import 'client_runtime.dart';
import 'download_archive.dart';
import 'drive/drive_manager.dart';
import 'drive/mount_store.dart';
import 'file_transfer.dart';
import 'local_command.dart';
import 'remote_path.dart';

/// Registers the file-transfer and OmnyDrive local commands — `:download`,
/// `:upload` and `:drive` — on a [LocalCommandRegistry].
///
/// These commands need local filesystem access (`dart:io`) and OmnyDrive, so
/// they cannot compile to JavaScript and are kept out of the browser-safe
/// default set ([LocalCommandRegistry.withDefaults]). Native embedders such as
/// the CLI opt in with `LocalCommandRegistry.withDefaults()..addFileTransferCommands()`.
extension FileTransferCommands on LocalCommandRegistry {
  /// Adds `:download`, `:upload` and `:drive` to this registry.
  void addFileTransferCommands() {
    register(_DownloadCommand());
    register(_UploadCommand());
    register(_DriveCommand());
  }
}

bool _endsWithSep(String p) =>
    p.endsWith('/') || p.endsWith(Platform.pathSeparator);

/// Joins a local directory [dir] and a file [name], inserting a separator only
/// when [dir] does not already end with one.
String _joinLocal(String dir, String name) {
  if (dir.isEmpty) return name;
  return _endsWithSep(dir) ? '$dir$name' : '$dir/$name';
}

/// Describes, in plain words, how the destination path was resolved.
String _modeExplanation(TransferPreflight pf) {
  if (pf.into) return 'directory → source kept inside it';
  final singleFile =
      pf.entries.length == 1 && !pf.entries.first.path.contains('/');
  return singleFile
      ? 'target path → source written as this name'
      : 'new path → becomes the copied directory root';
}

/// Per-entry status against the destination.
String _entryTag(TransferPreflight pf, ManifestEntry e) {
  final have = pf.have[e.path] ?? 0;
  if (have >= e.size && e.size > 0) return 'overwrite';
  if (have > 0 && have < e.size) return 'resume';
  return 'new';
}

/// Builds a confirmation hook that spells out the resolved destination and the
/// exact target path of each file, then asks the user to proceed. Sets
/// [onCancel] when the user declines.
Future<bool> Function(TransferPreflight) _confirmHook(
  LocalCommandContext c,
  void Function() onCancel,
) => (pf) async {
  c.writeLine('Destination: ${pf.dest}  (${_modeExplanation(pf)})');
  c.writeLine('  ${pf.entries.length} file(s), ${formatBytes(pf.total)} total');
  const cap = 10;
  for (final e in pf.entries.take(cap)) {
    c.writeLine('  ${pf.targetFor(e.path)}  [${_entryTag(pf, e)}]');
  }
  if (pf.entries.length > cap) {
    c.writeLine('  … and ${pf.entries.length - cap} more');
  }
  if (pf.overwrites.isNotEmpty) {
    c.writeLine(
      '  ⚠ ${pf.overwrites.length} existing file(s) will be replaced',
    );
  }
  if (c.readLine == null) return true; // non-interactive host: proceed
  final answer = (await c.readLine!('Proceed? [y/N] ')).trim().toLowerCase();
  final ok = answer == 'y' || answer == 'yes';
  if (!ok) {
    c.writeLine('Cancelled.');
    onCancel();
  }
  return ok;
};

class _DownloadCommand extends LocalCommand {
  @override
  String get name => 'download';
  @override
  List<String> get aliases => const ['get'];
  @override
  String get description =>
      'Download a remote file/dir (optionally as --zip/--gz/--tar.gz)';

  static const _usage =
      'usage: :download <remotePath> [localDestOrDir] [--zip|--gz|--tar.gz]';

  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final positionals = <String>[];
    ArchiveFormat? format;
    for (final a in args) {
      if (a.startsWith('--')) {
        final parsed = parseArchiveFlag(a);
        if (parsed == null) {
          c.writeLine(_usage);
          return;
        }
        format = parsed;
      } else {
        positionals.add(a);
      }
    }
    if (positionals.isEmpty) {
      c.writeLine(_usage);
      return;
    }
    final remote = resolveRemotePath(
      positionals.first,
      cwd: c.currentRemoteCwd?.call(),
    );
    final rawLocal = positionals.length > 1 ? positionals[1] : null;

    if (format == null) {
      await _downloadPlain(c, remote, rawLocal ?? '.');
    } else {
      await _downloadArchive(c, remote, rawLocal, format);
    }
  }

  /// The existing behavior: stream the remote path to a local file or directory.
  Future<void> _downloadPlain(
    LocalCommandContext c,
    String remote,
    String rawLocal,
  ) async {
    final destIsDir = _endsWithSep(rawLocal);
    final localDest = File(rawLocal).absolute.path;
    c.writeLine('Download: $remote  →  $localDest');

    final tx = ClientRuntime(c.requireClient.config);
    final bar = ProgressBar();
    var cancelled = false;
    try {
      await tx.connect();
      final result = await downloadPath(
        client: tx,
        nodeId: c.node.id.value,
        remotePath: remote,
        localDest: localDest,
        destIsDir: destIsDir,
        onProgress: bar.update,
        confirm: _confirmHook(c, () => cancelled = true),
      );
      bar.finish();
      if (cancelled) return;
      _report(c, result, 'Downloaded');
    } on Object catch (e) {
      bar.finish();
      c.writeLine('Download failed: $e');
    } finally {
      await tx.close();
    }
  }

  /// Builds an archive of [remote] on the node, then downloads the single
  /// archive file, removing the remote temp afterward.
  Future<void> _downloadArchive(
    LocalCommandContext c,
    String remote,
    String? rawLocal,
    ArchiveFormat format,
  ) async {
    final nodeId = c.node.id.value;

    // Determine whether the remote path is a directory, a file, or missing.
    final bool isDir;
    try {
      final probe = await c.requireClient.execute(
        nodeId: nodeId,
        command:
            '[ -d ${shQuote(remote)} ] && echo d || '
            '{ [ -e ${shQuote(remote)} ] && echo f || echo n; }',
      );
      final kind = utf8.decode(probe.stdout, allowMalformed: true).trim();
      if (kind == 'n') {
        c.writeLine('No such remote file or directory: $remote');
        return;
      }
      isDir = kind == 'd';
    } on Object catch (e) {
      c.writeLine('Download failed: $e');
      return;
    }

    final invalid = archiveError(format, isDir: isDir);
    if (invalid != null) {
      c.writeLine(invalid);
      return;
    }

    // Compress on the node into a temp file whose path it prints back.
    final ext = archiveExtension(format);
    c.writeLine('Compressing $remote as .$ext on the node…');
    final String remoteTmp;
    try {
      final res = await c.requireClient.execute(
        nodeId: nodeId,
        command: remoteArchiveCommand(remote, format: format, isDir: isDir),
      );
      if (res.exitCode != 0) {
        final msg = utf8.decode(res.stderr, allowMalformed: true).trim();
        c.writeLine('Compression failed${msg.isEmpty ? '' : ': $msg'}');
        return;
      }
      remoteTmp = utf8.decode(res.stdout, allowMalformed: true).trim();
      if (remoteTmp.isEmpty) {
        c.writeLine('Compression failed: no archive produced');
        return;
      }
    } on Object catch (e) {
      c.writeLine('Compression failed: $e');
      return;
    }

    // Resolve the local archive path: an explicit file, into a directory, or a
    // default name in the current directory.
    final defaultName = '${remoteBasename(remote)}.$ext';
    final String localFile;
    if (rawLocal == null) {
      localFile = defaultName;
    } else if (_endsWithSep(rawLocal) || Directory(rawLocal).existsSync()) {
      localFile = _joinLocal(rawLocal, defaultName);
    } else {
      localFile = rawLocal;
    }
    final localDest = File(localFile).absolute.path;
    c.writeLine('Download: $remote  →  $localDest');

    final tx = ClientRuntime(c.requireClient.config);
    final bar = ProgressBar();
    var cancelled = false;
    try {
      await tx.connect();
      final result = await downloadPath(
        client: tx,
        nodeId: nodeId,
        remotePath: remoteTmp,
        localDest: localDest,
        destIsDir: false,
        onProgress: bar.update,
        confirm: _confirmHook(c, () => cancelled = true),
      );
      bar.finish();
      if (cancelled) return;
      c.writeLine('Saved archive: $localDest');
      _report(c, result, 'Downloaded');
    } on Object catch (e) {
      bar.finish();
      c.writeLine('Download failed: $e');
    } finally {
      await tx.close();
      // Best-effort cleanup of the remote temp archive.
      try {
        await c.requireClient.execute(
          nodeId: nodeId,
          command: 'rm -f ${shQuote(remoteTmp)}',
        );
      } on Object {
        // Ignore: the node's temp dir is cleaned periodically anyway.
      }
    }
  }
}

class _UploadCommand extends LocalCommand {
  @override
  String get name => 'upload';
  @override
  List<String> get aliases => const ['put'];
  @override
  String get description => 'Upload a local file/dir to a remote path or dir';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    if (args.isEmpty) {
      c.writeLine('usage: :upload <localPath> [remoteDestOrDir]');
      return;
    }
    final localPath = args.first;
    if (!File(localPath).existsSync() && !Directory(localPath).existsSync()) {
      c.writeLine('No such local file or directory: $localPath');
      return;
    }
    // The trailing separator (if any) is preserved so the node can tell a
    // directory destination from an explicit target name.
    final remoteDest = resolveRemotePath(
      args.length > 1 ? args[1] : '.',
      cwd: c.currentRemoteCwd?.call(),
    );
    c.writeLine('Upload: ${File(localPath).absolute.path}  →  $remoteDest');

    final tx = ClientRuntime(c.requireClient.config);
    final bar = ProgressBar();
    var cancelled = false;
    try {
      await tx.connect();
      final result = await uploadPath(
        client: tx,
        nodeId: c.node.id.value,
        localPath: localPath,
        remoteDir: remoteDest,
        onProgress: bar.update,
        confirm: _confirmHook(c, () => cancelled = true),
      );
      bar.finish();
      if (cancelled) return;
      _report(c, result, 'Uploaded');
    } on Object catch (e) {
      bar.finish();
      c.writeLine('Upload failed: $e');
    } finally {
      await tx.close();
    }
  }
}

void _report(LocalCommandContext c, TransferResult result, String verb) {
  if (result.ok) {
    c.writeLine(
      '$verb ${result.verified.length} file(s); all hashes verified.',
    );
    return;
  }
  c.writeLine(
    '$verb ${result.verified.length} file(s); '
    '${result.failures.length} failed:',
  );
  result.failures.forEach((path, reason) => c.writeLine('  $path: $reason'));
  c.writeLine('Re-run the command to retry failed/partial files.');
}

/// Splits drive [args] into positionals and flags. A flag named in [valueFlags]
/// consumes the following token (or the `=value` suffix) as its value; a flag
/// named in [multiFlags] does the same but is repeatable, accumulating into
/// [multi]; any other `--flag` becomes a boolean set to `'true'`. Mirrors the
/// small subset of the CLI `args` grammar the `:drive` subcommands need.
({
  List<String> positionals,
  Map<String, String> flags,
  Map<String, List<String>> multi,
})
_parseDriveFlags(
  List<String> args,
  Set<String> valueFlags, {
  Set<String> multiFlags = const {},
}) {
  final positionals = <String>[];
  final flags = <String, String>{};
  final multi = <String, List<String>>{};
  void addMulti(String name, String value) =>
      (multi[name] ??= <String>[]).add(value);
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) {
      positionals.add(a);
      continue;
    }
    final body = a.substring(2);
    final eq = body.indexOf('=');
    if (eq >= 0) {
      final name = body.substring(0, eq);
      final value = body.substring(eq + 1);
      if (multiFlags.contains(name)) {
        addMulti(name, value);
      } else {
        flags[name] = value;
      }
      continue;
    }
    if (multiFlags.contains(body)) {
      addMulti(body, i + 1 < args.length ? args[++i] : '');
    } else if (valueFlags.contains(body)) {
      flags[body] = i + 1 < args.length ? args[++i] : '';
    } else {
      flags[body] = 'true';
    }
  }
  return (positionals: positionals, flags: flags, multi: multi);
}

/// One status line for a mount, scoped to the current node (so the node id is
/// dropped from the target). Mirrors the CLI's `_mountLine`.
String _driveMountLine(MountRecord r) {
  final st = r.syncState;
  final src = r.isGit ? (r.gitUrl ?? 'git') : (r.localPath ?? '?');
  final mode = r.readWrite ? 'rw' : 'ro';
  return '${r.id.padRight(22)} ${st.status.wireValue.padRight(10)} '
      '$mode  $src -> ${r.remotePath}';
}

/// Manages OmnyDrive mounts on the current session's node via [DriveManager].
///
/// The node is implicit (the connected session's node), so paths take no
/// `<node>:` prefix and every operation is scoped to that node: `ls` lists only
/// this node's mounts and a mount-id belonging to another node is refused.
class _DriveCommand extends LocalCommand {
  /// Background watchers keyed by mount id. Completing a watcher's future stops
  /// it (see [DriveManager.watch]'s `until`). State lives on the command
  /// instance, which the registry keeps for the whole session.
  final Map<String, Completer<void>> _watchers = {};

  @override
  String get name => 'drive';

  @override
  String get description =>
      'Manage OmnyDrive mounts on this node (mount/ls/sync/watch/…)';

  @override
  String? get usage =>
      ':drive <subcommand>   Manage OmnyDrive mounts on the current node.\n'
      '    The node is fixed to this session; paths take no <node>: prefix.\n'
      '\n'
      '    :drive ls                                     List this node\'s mounts\n'
      '    :drive mount <local-dir> <remote-path> [--rw] [--no-initial-sync] [--name N]\n'
      '                                              [--include G] [--exclude G] [--ignore-file N]\n'
      '    :drive mount --git <url> <remote-path> [--rw] [--branch B] [--depth N] [--name N]\n'
      '    :drive status <mount-id>                      Show a mount\'s sync state\n'
      '    :drive sync <mount-id> [--push|--pull]        Synchronize once\n'
      '    :drive diff <mount-id> <file-path>            Show a file\'s divergence\n'
      '    :drive conflicts <mount-id> [--diff]          List diverging files (no sync)\n'
      '    :drive resolve <mount-id> [<file-path>] [--accept-local|--accept-origin|--reclone]\n'
      '    :drive remount <mount-id>                     Re-establish after a restart\n'
      '    :drive unmount <mount-id> [--sync-first] [--no-keep-remote]\n'
      '    :drive watch <mount-id> [--interval S] [--debounce MS]   Background auto-sync\n'
      '    :drive unwatch [<mount-id>]                   Stop background watcher(s)';

  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final sub = args.isEmpty ? 'ls' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    try {
      switch (sub) {
        case 'ls':
        case 'list':
          await _ls(c);
        case 'mount':
          await _mount(c, rest);
        case 'status':
          await _status(c, rest);
        case 'sync':
          await _sync(c, rest);
        case 'diff':
          await _diff(c, rest);
        case 'conflicts':
          await _conflicts(c, rest);
        case 'resolve':
          await _resolve(c, rest);
        case 'remount':
          await _remount(c, rest);
        case 'unmount':
          await _unmount(c, rest);
        case 'watch':
          await _watch(c, rest);
        case 'unwatch':
          await _unwatch(c, rest);
        default:
          c.writeLine('Unknown :drive subcommand "$sub".');
          c.writeLine(usage!);
      }
    } on DriveException catch (e) {
      c.writeLine('drive: ${e.message}');
    } on Object catch (e) {
      c.writeLine('drive: $e');
    }
  }

  Future<DriveManager> _manager(LocalCommandContext c) =>
      DriveManager.open(c.requireClient);

  /// A throttled progress sink that prints live sync status above the prompt
  /// (or inline when the host has no [LocalCommandContext.printAbove]). A
  /// carriage-return bar would fight the readline input, so each update is a
  /// fresh `syncing N/M: path` line. [prefix] tags watcher output.
  DriveProgress _progressSink(LocalCommandContext c, {String prefix = ''}) {
    final out = c.printAbove ?? c.writeLine;
    final sw = Stopwatch()..start();
    var lastMs = -1000;
    return (ProgressEvent e) {
      final line = formatSyncProgress(e);
      if (line == null) return;
      final last = e.total != null && e.completed == e.total;
      final ms = sw.elapsedMilliseconds;
      if (!last && ms - lastMs < 150) return;
      lastMs = ms;
      out('$prefix$line');
    };
  }

  /// Looks up [id] and asserts it belongs to the current node. Returns `null`
  /// (after writing an explanation) when the mount is missing or on another node.
  MountRecord? _scoped(LocalCommandContext c, DriveManager mgr, String id) {
    final r = mgr.get(id);
    if (r == null) {
      c.writeLine('drive: no such mount: $id');
      return null;
    }
    if (r.nodeId != c.node.id.value) {
      c.writeLine(
        'drive: mount $id is on node ${r.nodeId}, not this session\'s node '
        '(${c.node.id.value}).',
      );
      return null;
    }
    return r;
  }

  Future<void> _ls(LocalCommandContext c) async {
    final mgr = await _manager(c);
    final mounts = mgr
        .list()
        .where((r) => r.nodeId == c.node.id.value)
        .toList();
    if (mounts.isEmpty) {
      c.writeLine('No mounts on this node.');
      return;
    }
    for (final r in mounts) {
      c.writeLine(_driveMountLine(r));
    }
  }

  Future<void> _mount(LocalCommandContext c, List<String> args) async {
    final p = _parseDriveFlags(
      args,
      const {'name', 'git', 'branch', 'depth', 'ignore-file'},
      multiFlags: const {'include', 'exclude'},
    );
    final mgr = await _manager(c);
    final nodeId = c.node.id.value;
    final gitUrl = p.flags['git'];
    final include = p.multi['include'] ?? const <String>[];
    final exclude = p.multi['exclude'] ?? const <String>[];
    final MountRecord rec;
    if (gitUrl != null && gitUrl.isNotEmpty) {
      if (include.isNotEmpty || exclude.isNotEmpty) {
        c.writeLine(
          'drive: --include/--exclude only apply to directory mounts, not --git.',
        );
        return;
      }
      if (p.flags.containsKey('ignore-file')) {
        c.writeLine(
          'drive: --ignore-file only applies to directory mounts, not --git.',
        );
        return;
      }
      if (p.positionals.isEmpty) {
        c.writeLine(
          'usage: :drive mount --git <url> <remote-path> '
          '[--rw] [--branch B] [--depth N] [--name N]',
        );
        return;
      }
      rec = await mgr.mountGit(
        url: gitUrl,
        nodeId: nodeId,
        remotePath: p.positionals.first,
        name: p.flags['name'],
        branch: p.flags['branch'],
        depth: int.tryParse(p.flags['depth'] ?? ''),
        readWrite: p.flags.containsKey('rw'),
        onProgress: _progressSink(c),
      );
    } else {
      if (p.positionals.length < 2) {
        c.writeLine(
          'usage: :drive mount <local-dir> <remote-path> '
          '[--rw] [--no-initial-sync] [--name N] [--include G] [--exclude G] '
          '[--ignore-file N]',
        );
        return;
      }
      // No explicit --include/--exclude: fall back to the directory's
      // .omnyignore (or --ignore-file) as the default exclude set.
      final filter = await resolveDirMountFilter(
        localDir: p.positionals[0],
        explicit: (include.isEmpty && exclude.isEmpty)
            ? null
            : PathFilter(include: include, exclude: exclude),
        ignoreFileName: p.flags['ignore-file'],
      );
      rec = await mgr.mountDirectory(
        localDir: p.positionals[0],
        nodeId: nodeId,
        remotePath: p.positionals[1],
        name: p.flags['name'],
        readWrite: p.flags.containsKey('rw'),
        initialSync: !p.flags.containsKey('no-initial-sync'),
        filter: filter,
        onProgress: _progressSink(c),
      );
    }
    c.writeLine('Mounted ${rec.id}');
    c.writeLine('  ${_driveMountLine(rec)}');
  }

  Future<void> _status(LocalCommandContext c, List<String> args) async {
    if (args.isEmpty) {
      c.writeLine('usage: :drive status <mount-id>');
      return;
    }
    final mgr = await _manager(c);
    final r = _scoped(c, mgr, args.first);
    if (r == null) return;
    final st = r.syncState;
    c.writeLine('Mount:    ${r.id}');
    c.writeLine(
      'Kind:     ${r.kind} (${r.readWrite ? 'read-write' : 'read-only'})',
    );
    c.writeLine('Source:   ${r.isGit ? r.gitUrl : r.localPath}');
    c.writeLine('Target:   ${r.nodeId}:${r.remotePath}');
    c.writeLine('Status:   ${st.status.wireValue}');
    c.writeLine('Baseline: ${st.baselineRef}');
    c.writeLine('Synced:   ${st.lastSyncedAt?.toIso8601String() ?? 'never'}');
    if (st.lastError != null) c.writeLine('Error:    ${st.lastError}');
  }

  Future<void> _sync(LocalCommandContext c, List<String> args) async {
    final p = _parseDriveFlags(args, const {});
    if (p.positionals.isEmpty) {
      c.writeLine('usage: :drive sync <mount-id> [--push|--pull]');
      return;
    }
    final push = p.flags.containsKey('push');
    final pull = p.flags.containsKey('pull');
    if (push && pull) {
      c.writeLine('drive: choose only one of --push / --pull');
      return;
    }
    final mgr = await _manager(c);
    final id = p.positionals.first;
    if (_scoped(c, mgr, id) == null) return;
    final direction = push
        ? SyncDirection.push
        : pull
        ? SyncDirection.pull
        : null;
    _reportSync(
      c,
      await mgr.sync(id, direction: direction, onProgress: _progressSink(c)),
    );
  }

  void _reportSync(LocalCommandContext c, SyncOutcome o) {
    c.writeLine(formatSyncReport(o));
  }

  Future<void> _diff(LocalCommandContext c, List<String> args) async {
    if (args.length < 2) {
      c.writeLine('usage: :drive diff <mount-id> <file-path>');
      return;
    }
    final mgr = await _manager(c);
    final id = args.first;
    if (_scoped(c, mgr, id) == null) return;
    c.writeLine(formatFileDiff(await mgr.diffFile(id, args[1])).trimRight());
  }

  Future<void> _conflicts(LocalCommandContext c, List<String> args) async {
    final p = _parseDriveFlags(args, const {});
    if (p.positionals.isEmpty) {
      c.writeLine('usage: :drive conflicts <mount-id> [--diff]');
      return;
    }
    final mgr = await _manager(c);
    final id = p.positionals.first;
    if (_scoped(c, mgr, id) == null) return;
    final changes = await mgr.conflicts(
      id,
      includeDiffs: p.flags.containsKey('diff'),
    );
    c.writeLine(formatDriveChanges(changes, mountId: id));
  }

  Future<void> _resolve(LocalCommandContext c, List<String> args) async {
    final p = _parseDriveFlags(args, const {});
    if (p.positionals.isEmpty) {
      c.writeLine(
        'usage: :drive resolve <mount-id> [<file-path>] '
        '[--accept-local|--accept-origin|--reclone]',
      );
      return;
    }
    final reclone = p.flags.containsKey('reclone');
    final strategy = p.flags.containsKey('accept-origin')
        ? 'accept-origin'
        : reclone
        ? 'reclone'
        : 'accept-local';
    final mgr = await _manager(c);
    final id = p.positionals.first;
    if (_scoped(c, mgr, id) == null) return;
    if (p.positionals.length > 1) {
      if (reclone) {
        c.writeLine('drive: --reclone cannot be combined with a file path');
        return;
      }
      final o = await mgr.resolveFile(
        id,
        p.positionals[1],
        strategy: strategy,
        onProgress: _progressSink(c),
      );
      c.writeLine(
        'Resolved ${o.path} ($strategy).'
        '${o.converged ? ' Mount is now in sync.' : ' Other paths still diverge.'}',
      );
      return;
    }
    final o = await mgr.resolve(
      id,
      strategy: strategy,
      onProgress: _progressSink(c),
    );
    if (o.isConflict) {
      c.writeLine('Still conflicted: ${o.conflict!.message}');
    } else {
      c.writeLine('Resolved ($strategy): ${o.applied} change(s).');
    }
  }

  Future<void> _remount(LocalCommandContext c, List<String> args) async {
    if (args.isEmpty) {
      c.writeLine('usage: :drive remount <mount-id>');
      return;
    }
    final mgr = await _manager(c);
    final id = args.first;
    if (_scoped(c, mgr, id) == null) return;
    final rec = await mgr.remount(id, onProgress: _progressSink(c));
    c.writeLine('Remounted ${rec.id}.');
  }

  Future<void> _unmount(LocalCommandContext c, List<String> args) async {
    final p = _parseDriveFlags(args, const {});
    if (p.positionals.isEmpty) {
      c.writeLine(
        'usage: :drive unmount <mount-id> [--sync-first] [--no-keep-remote]',
      );
      return;
    }
    final mgr = await _manager(c);
    final id = p.positionals.first;
    if (_scoped(c, mgr, id) == null) return;
    // Stop any background watcher first so it cannot re-sync a torn-down mount.
    await _stopWatcher(id, c, announce: false);
    await mgr.unmount(
      id,
      syncFirst: p.flags.containsKey('sync-first'),
      keepRemote: !p.flags.containsKey('no-keep-remote'),
    );
    c.writeLine('Unmounted $id.');
  }

  Future<void> _watch(LocalCommandContext c, List<String> args) async {
    final p = _parseDriveFlags(args, const {'interval', 'debounce'});
    if (p.positionals.isEmpty) {
      c.writeLine(
        'usage: :drive watch <mount-id> [--interval S] [--debounce MS]',
      );
      return;
    }
    final id = p.positionals.first;
    if (_watchers.containsKey(id)) {
      c.writeLine(
        'drive: already watching $id (stop with :drive unwatch $id).',
      );
      return;
    }
    final mgr = await _manager(c);
    if (_scoped(c, mgr, id) == null) return;
    final interval = Duration(
      seconds: int.tryParse(p.flags['interval'] ?? '') ?? 15,
    );
    final debounce = Duration(
      milliseconds: int.tryParse(p.flags['debounce'] ?? '') ?? 500,
    );
    // Background output must repaint around the prompt; fall back to writeLine
    // when the host cannot (non-interactive).
    final log = c.printAbove ?? c.writeLine;
    final stop = Completer<void>();
    _watchers[id] = stop;
    // Fire and forget: the REPL stays usable while the watcher runs. It ends
    // when its completer is completed by :drive unwatch (or unmount/teardown).
    unawaited(() async {
      try {
        await mgr.watch(
          id,
          interval: interval,
          debounce: debounce,
          log: (m) => log('drive[$id]: $m'),
          onProgress: _progressSink(c, prefix: 'drive[$id]: '),
          until: stop.future,
        );
      } on Object catch (e) {
        log('drive[$id]: watch stopped: $e');
      } finally {
        _watchers.remove(id);
      }
    }());
    c.writeLine(
      'Watching $id in the background (stop with :drive unwatch $id).',
    );
  }

  Future<void> _unwatch(LocalCommandContext c, List<String> args) async {
    if (_watchers.isEmpty) {
      c.writeLine('drive: no background watchers running.');
      return;
    }
    if (args.isEmpty) {
      for (final id in _watchers.keys.toList()) {
        await _stopWatcher(id, c, announce: true);
      }
      return;
    }
    final id = args.first;
    if (!_watchers.containsKey(id)) {
      c.writeLine('drive: not watching $id.');
      return;
    }
    await _stopWatcher(id, c, announce: true);
  }

  Future<void> _stopWatcher(
    String id,
    LocalCommandContext c, {
    required bool announce,
  }) async {
    final stop = _watchers.remove(id);
    if (stop == null) return;
    if (!stop.isCompleted) stop.complete();
    if (announce) c.writeLine('Stopped watching $id.');
  }
}
