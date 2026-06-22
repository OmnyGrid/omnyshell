import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnydrive/omnydrive.dart'
    show PathFilter, ProgressEvent, SyncDirection;

import '../../domain/auth/principal.dart';
import '../../domain/backend/shell_family.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../shared/errors/omnyshell_exception.dart';
import '../../shared/utils/clock.dart';
import '../../version.dart';
import '../../shared/utils/progress_bar.dart';
import '../transfer/transfer_engine.dart';
import 'client_runtime.dart';
import 'download_archive.dart';
import 'drive/drive_manager.dart';
import 'drive/mount_store.dart';
import 'file_transfer.dart';
import 'remote_session.dart';

/// Runtime context passed to a [LocalCommand].
///
/// Exposes the connected client, the target node's metadata, the live session
/// and a line-oriented output sink. Commands call [requestExit] to end the
/// interactive session.
class LocalCommandContext {
  /// The connected client runtime.
  final ClientRuntime client;

  /// The node the session is attached to.
  final NodeDescriptor node;

  /// The authenticated principal, if known.
  final Principal? principal;

  /// The active interactive session, if one is open.
  final RemoteSession? session;

  /// When the interactive session started.
  final DateTime startedAt;

  /// The clock used for duration/latency reporting.
  final Clock clock;

  /// Writes a line of output back to the user.
  final void Function(String line) writeLine;

  /// Reads a line of user input after writing [prompt]; `null` when the host
  /// cannot prompt (commands then assume a non-interactive default).
  final Future<String> Function(String prompt)? readLine;

  /// Returns the current remote working directory, if known, so commands can
  /// resolve relative remote paths. `null` when unavailable.
  final String? Function()? currentRemoteCwd;

  /// Emits a line of asynchronous/background output without disturbing the
  /// active input line (e.g. a background `:drive watch` reporting a sync).
  /// `null` when the host cannot repaint around output; callers then fall back
  /// to [writeLine].
  final void Function(String line)? printAbove;

  bool _exitRequested = false;
  bool _detachRequested = false;

  /// Creates a command context.
  LocalCommandContext({
    required this.client,
    required this.node,
    required this.startedAt,
    required this.writeLine,
    this.principal,
    this.session,
    this.clock = const SystemClock(),
    this.readLine,
    this.currentRemoteCwd,
    this.printAbove,
  });

  /// Whether a command requested the session to end.
  bool get exitRequested => _exitRequested;

  /// Whether a command detached the session (the remote shell keeps running).
  /// When set, the host must drop the connection *without* closing the session.
  bool get detachRequested => _detachRequested;

  /// Requests that the interactive session terminate (closing the remote shell).
  void requestExit() => _exitRequested = true;

  /// Requests that the host leave the interactive session because it was
  /// detached: the connection should be dropped but the session left running.
  void requestDetach() {
    _detachRequested = true;
    _exitRequested = true;
  }
}

/// A local OmnyShell command, invoked with a leading `:` and never forwarded to
/// the remote shell.
abstract class LocalCommand {
  /// The command name (without the leading `:`).
  String get name;

  /// A one-line description shown by `:help`.
  String get description;

  /// Aliases that also invoke this command.
  List<String> get aliases => const [];

  /// Optional multi-line usage/help text shown under the listing by `:help`.
  String? get usage => null;

  /// Runs the command with parsed [args].
  Future<void> run(LocalCommandContext context, List<String> args);
}

/// An extensible registry of local `:` commands.
///
/// Third-party packages register custom [LocalCommand]s to extend the
/// interactive experience. The built-in set is installed by
/// [LocalCommandRegistry.withDefaults].
class LocalCommandRegistry {
  final Map<String, LocalCommand> _byName = {};

  /// Creates an empty registry.
  LocalCommandRegistry();

  /// Creates a registry pre-populated with the built-in commands.
  factory LocalCommandRegistry.withDefaults() {
    final registry = LocalCommandRegistry();
    for (final command in _builtIns) {
      registry.register(command);
    }
    return registry;
  }

  /// The registered commands (de-duplicated, sorted by name).
  List<LocalCommand> get commands {
    final unique = <LocalCommand>{..._byName.values}.toList();
    unique.sort((a, b) => a.name.compareTo(b.name));
    return unique;
  }

  /// Registers [command] under its name and aliases.
  ///
  /// Throws [ArgumentError] if a name/alias is already taken.
  void register(LocalCommand command) {
    for (final key in [command.name, ...command.aliases]) {
      if (_byName.containsKey(key)) {
        throw ArgumentError.value(key, 'command', 'already registered');
      }
      _byName[key] = command;
    }
  }

  /// Whether [line] is a local command (begins with `:`).
  bool isLocalCommand(String line) => line.trimLeft().startsWith(':');

  /// Handles a local-command [line], returning `true` if a command ran.
  ///
  /// Unknown commands write an error via [LocalCommandContext.writeLine] and
  /// still return `true` (the line was a local command, just not recognised).
  Future<bool> handle(String line, LocalCommandContext context) async {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith(':')) return false;
    final parts = trimmed.substring(1).trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return true;
    final command = _byName[parts.first];
    if (command == null) {
      context.writeLine('Unknown command: :${parts.first}');
      return true;
    }
    await command.run(context, parts.sublist(1));
    return true;
  }

  static final List<LocalCommand> _builtIns = [
    _HelpCommand(),
    _InfoCommand(),
    _WhoamiCommand(),
    _OsCommand(),
    _ArchCommand(),
    _HostCommand(),
    _NodeCommand(),
    _CapabilitiesCommand(),
    _SessionCommand(),
    _LatencyCommand(),
    _PingCommand(),
    _TunnelCommand(),
    _TreeCommand(),
    _DownloadCommand(),
    _UploadCommand(),
    _DriveCommand(),
    _DetachCommand(),
    _ExitCommand(),
  ];
}

String _formatDuration(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

class _HelpCommand extends LocalCommand {
  @override
  String get name => 'help';
  @override
  String get description => 'List local commands';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final commands = LocalCommandRegistry.withDefaults().commands;
    c.writeLine('OmnyShell v$omnyShellVersion');
    c.writeLine('');
    c.writeLine('Local commands:');
    for (final cmd in commands) {
      c.writeLine('  :${cmd.name.padRight(14)} ${cmd.description}');
    }
    for (final cmd in commands) {
      final usage = cmd.usage;
      if (usage == null) continue;
      c.writeLine('');
      for (final line in usage.split('\n')) {
        c.writeLine(line);
      }
    }
  }
}

class _InfoCommand extends LocalCommand {
  @override
  String get name => 'info';
  @override
  String get description => 'Show node and session info';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final node = c.node;
    final name = node.displayName;
    c.writeLine('Node: ${node.id.value}${name.isEmpty ? '' : ' ($name)'}');
    if (node.uid != null) c.writeLine('UID: ${node.uid!.value}');
    c.writeLine('OS: ${node.platform.os}');
    c.writeLine('Arch: ${node.platform.arch}');
    c.writeLine('Hostname: ${node.platform.hostname}');
    c.writeLine('Agent: ${node.platform.agentVersion}');
    c.writeLine('Hub: ${c.client.config.hubUri}');
    if (node.labels.isNotEmpty) {
      c.writeLine(
        'Labels: '
        '${node.labels.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
      );
    }
    final s = c.session;
    if (s != null) {
      c.writeLine('Shell: ${_shellFamilyLabel(s.shellFamily)}');
      c.writeLine('Session: ${s.id?.value ?? '(pending)'} (${s.mode.name})');
    }
    c.writeLine(
      'Session Duration: '
      '${_formatDuration(c.clock.now().difference(c.startedAt))}',
    );
  }
}

/// A human-readable label for the remote shell's command-language family.
String _shellFamilyLabel(ShellFamily family) => switch (family) {
  ShellFamily.posix => 'POSIX (sh/bash)',
  ShellFamily.powershell => 'PowerShell',
  ShellFamily.cmd => 'cmd.exe',
};

class _WhoamiCommand extends LocalCommand {
  @override
  String get name => 'whoami';
  @override
  String get description => 'Show the authenticated principal';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final p = c.principal;
    if (p == null) {
      c.writeLine('Not authenticated');
      return;
    }
    c.writeLine('${p.displayName} (${p.id.value})');
    c.writeLine('Roles: ${(p.roles.toList()..sort()).join(', ')}');
  }
}

class _OsCommand extends LocalCommand {
  @override
  String get name => 'os';
  @override
  String get description => "Show the node's operating system";
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async =>
      c.writeLine(c.node.platform.os);
}

class _ArchCommand extends LocalCommand {
  @override
  String get name => 'arch';
  @override
  String get description => "Show the node's architecture";
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async =>
      c.writeLine(c.node.platform.arch);
}

class _HostCommand extends LocalCommand {
  @override
  String get name => 'host';
  @override
  String get description => "Show the node's hostname";
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async =>
      c.writeLine(c.node.platform.hostname);
}

class _NodeCommand extends LocalCommand {
  @override
  String get name => 'node';
  @override
  String get description => 'Show the node id and labels';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    c.writeLine('Node: ${c.node.id.value} (${c.node.displayName})');
    if (c.node.labels.isNotEmpty) {
      c.writeLine(
        'Labels: '
        '${c.node.labels.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
      );
    }
  }
}

class _CapabilitiesCommand extends LocalCommand {
  @override
  String get name => 'capabilities';
  @override
  String get description => 'Show advertised node capabilities';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final caps = c.node.capabilities;
    if (caps == null) {
      c.writeLine('No capabilities advertised');
      return;
    }
    c.writeLine('Shells: ${caps.shells.join(', ')}');
    c.writeLine('Features: ${caps.features.join(', ')}');
    c.writeLine('Max sessions: ${caps.maxSessions}');
  }
}

class _SessionCommand extends LocalCommand {
  @override
  String get name => 'session';
  @override
  String get description => 'Show the current session';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final s = c.session;
    c.writeLine('Session: ${s?.id?.value ?? '(none)'}');
    c.writeLine('Mode: ${s?.mode.name ?? '(none)'}');
    c.writeLine(
      'Duration: ${_formatDuration(c.clock.now().difference(c.startedAt))}',
    );
  }
}

class _LatencyCommand extends LocalCommand {
  @override
  String get name => 'latency';
  @override
  String get description => 'Measure round-trip latency to the Hub';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final rtt = await c.client.ping();
    c.writeLine('RTT: ${rtt.inMilliseconds}ms');
  }
}

class _PingCommand extends LocalCommand {
  @override
  String get name => 'ping';
  @override
  String get description => 'Ping the Hub (optionally N times, e.g. :ping 3)';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    var count = 1;
    if (args.isNotEmpty) {
      final n = int.tryParse(args.first);
      if (n == null || n < 1) {
        c.writeLine('usage: :ping [count] (count must be a positive integer)');
        return;
      }
      count = n;
    }

    final samples = <int>[];
    for (var i = 0; i < count; i++) {
      final ms = (await c.client.ping()).inMilliseconds;
      samples.add(ms);
      c.writeLine(count == 1 ? 'pong ${ms}ms' : 'pong ${i + 1}/$count ${ms}ms');
    }
    if (count > 1) {
      final min = samples.reduce((a, b) => a < b ? a : b);
      final max = samples.reduce((a, b) => a > b ? a : b);
      final avg = (samples.reduce((a, b) => a + b) / samples.length).round();
      c.writeLine(
        '--- $count pings · min ${min}ms · avg ${avg}ms · max ${max}ms',
      );
    }
  }
}

class _TunnelCommand extends LocalCommand {
  @override
  String get name => 'tunnel';
  @override
  String get description => "Expose this node's TCP port through the Hub";
  @override
  String? get usage =>
      ':tunnel <subcommand>   Forward a node TCP port through a public Hub port.\n'
      '\n'
      "    :tunnel <port> [--public-port N] [--secure]   Expose this node's localhost:<port>\n"
      '    :tunnel ls                                    List your active tunnels on this node\n'
      '    :tunnel close <id>                            Close a tunnel by id or prefix';

  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    if (args.isEmpty) {
      c.writeLine(
        'usage: :tunnel <port> [--public-port N] [--secure] | :tunnel ls | '
        ':tunnel close <id>',
      );
      return;
    }
    switch (args.first) {
      case 'ls':
      case 'list':
        await _list(c);
      case 'close':
      case 'rm':
        await _close(c, args.sublist(1));
      default:
        await _open(c, args.first == 'open' ? args.sublist(1) : args);
    }
  }

  Future<void> _open(LocalCommandContext c, List<String> args) async {
    int? targetPort;
    int? publicPort;
    var secure = false;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--public-port' || a == '-p') {
        if (i + 1 >= args.length) {
          c.writeLine('usage: :tunnel <port> [--public-port N] [--secure]');
          return;
        }
        publicPort = int.tryParse(args[++i]);
        if (publicPort == null) {
          c.writeLine('tunnel: invalid --public-port value');
          return;
        }
      } else if (a == '--secure' || a == '-s') {
        secure = true;
      } else {
        targetPort ??= int.tryParse(a);
      }
    }
    if (targetPort == null || targetPort < 1 || targetPort > 65535) {
      c.writeLine(
        'usage: :tunnel <port> [--public-port N] [--secure] (port 1-65535)',
      );
      return;
    }
    try {
      final t = await c.client.openTunnel(
        nodeId: c.node.id.value,
        targetPort: targetPort,
        publicPort: publicPort,
        secure: secure,
      );
      final host = t.publicHost.isEmpty
          ? c.client.config.hubUri.host
          : t.publicHost;
      final scheme = t.secure ? 'https://' : '';
      c.writeLine(
        'Tunnel ${t.shortId} open: $scheme$host:${t.publicPort} -> '
        '${c.node.id.value}:${t.targetPort}',
      );
      c.writeLine('Close with :tunnel close ${t.shortId}');
    } on Object catch (e) {
      c.writeLine('tunnel: ${_describe(e)}');
    }
  }

  Future<void> _list(LocalCommandContext c) async {
    try {
      final tunnels = await c.client.listTunnels();
      final mine = tunnels.where((t) => t.nodeId == c.node.id.value).toList();
      if (mine.isEmpty) {
        c.writeLine('No tunnels on ${c.node.id.value}.');
        return;
      }
      for (final t in mine) {
        final host = t.publicHost.isEmpty
            ? c.client.config.hubUri.host
            : t.publicHost;
        c.writeLine(
          '${t.shortId}  $host:${t.publicPort} -> '
          '${t.targetHost}:${t.targetPort}',
        );
      }
    } on Object catch (e) {
      c.writeLine('tunnel: ${_describe(e)}');
    }
  }

  Future<void> _close(LocalCommandContext c, List<String> args) async {
    if (args.isEmpty) {
      c.writeLine('usage: :tunnel close <id>');
      return;
    }
    try {
      final res = await c.client.closeTunnel(args.first);
      c.writeLine(res.ok ? 'Tunnel closed.' : 'tunnel: ${res.message}');
    } on Object catch (e) {
      c.writeLine('tunnel: ${_describe(e)}');
    }
  }

  String _describe(Object e) =>
      e is OmnyShellException ? e.message : e.toString();
}

class _TreeCommand extends LocalCommand {
  /// Default maximum display depth when `-L` is not given.
  static const _defaultDepth = 3;

  @override
  String get name => 'tree';
  @override
  String get description => 'Print a sized directory tree of a remote path';
  @override
  String? get usage =>
      ':tree [path] [-L depth] [-a]\n'
      '    Print a tree of a remote path (default: current dir) showing the\n'
      '    size of every file and the aggregated size of every directory.\n'
      '    -L depth   limit display depth (default $_defaultDepth; 0 = unlimited)\n'
      '    -a         include hidden entries (dot-files)';

  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    const usageLine = 'usage: :tree [path] [-L depth] [-a]';
    var depth = _defaultDepth;
    var all = false;
    String? path;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '-a' || a == '--all') {
        all = true;
      } else if (a == '-L') {
        final v = i + 1 < args.length ? args[++i] : null;
        final n = v == null ? null : int.tryParse(v);
        if (n == null || n < 0) {
          c.writeLine('$usageLine  (depth must be a non-negative integer)');
          return;
        }
        depth = n;
      } else if (a.startsWith('-L')) {
        final n = int.tryParse(a.substring(2));
        if (n == null || n < 0) {
          c.writeLine('$usageLine  (depth must be a non-negative integer)');
          return;
        }
        depth = n;
      } else if (a.startsWith('-')) {
        c.writeLine(usageLine);
        return;
      } else if (path != null) {
        c.writeLine(usageLine);
        return;
      } else {
        path = a;
      }
    }

    var remote = _resolveRemote(c, path ?? '.');
    // Collapse a trailing '/.' (produced when resolving '.') and any trailing
    // separator so the start point and its children share a clean prefix.
    if (remote.endsWith('/.')) remote = remote.substring(0, remote.length - 2);
    if (remote.length > 1 && remote.endsWith('/')) {
      remote = remote.substring(0, remote.length - 1);
    }

    final os = c.node.platform.os.toLowerCase();
    final isBsd = os.contains('mac') || os.contains('darwin');
    final statCmd = isBsd ? r"stat -f '%HT|%z|%N'" : r"stat -c '%F|%s|%n'";

    // Prune hidden entries at the node unless `-a`, or unless the user pointed
    // directly at a hidden path (so `:tree .config` still lists its contents).
    final base = _remoteBasename(remote);
    final rootHidden = base.startsWith('.') && base != '.' && base != '..';
    final prune = !all && !rootHidden;
    final find = prune
        ? "find ${_shQuote(remote)} \\( -name '.?*' -prune \\) -o "
              '-exec $statCmd {} +'
        : 'find ${_shQuote(remote)} -exec $statCmd {} +';

    final ExecResult res;
    try {
      res = await c.client.execute(nodeId: c.node.id.value, command: find);
    } on Object catch (e) {
      c.writeLine('tree failed: $e');
      return;
    }
    if (res.exitCode != 0) {
      // Remote tool output may not be UTF-8 (e.g. a Windows node's OEM-codepage
      // error text), so decode tolerantly rather than throwing.
      final msg = utf8.decode(res.stderr, allowMalformed: true).trim();
      c.writeLine(
        msg.isEmpty ? 'tree: failed (exit ${res.exitCode})' : 'tree: $msg',
      );
      return;
    }

    final entries = parseStatLines(
      utf8.decode(res.stdout, allowMalformed: true),
    );
    if (entries.isEmpty) {
      c.writeLine('No such remote file or directory: $remote');
      return;
    }
    for (final line in renderTree(remote, entries, maxDepth: depth)) {
      c.writeLine(line);
    }
  }
}

/// A single `find … -exec stat …` entry: its absolute [path], byte [size] and
/// whether it is a directory or a symlink (leaf; never followed).
typedef StatEntry = ({String path, int size, bool isDir, bool isLink});

/// Parses the `TYPE|SIZE|PATH` lines emitted by the node's `find`/`stat` run.
///
/// The type field is a human word — GNU `%F` (`directory`/`regular file`/
/// `symbolic link`) or BSD `%HT` (`Directory`/`Regular File`/`Symbolic Link`).
/// Only the first two `|` separate the fields, so a `|` in a path is preserved.
List<StatEntry> parseStatLines(String stdout) {
  final out = <StatEntry>[];
  for (final line in const LineSplitter().convert(stdout)) {
    if (line.isEmpty) continue;
    final i1 = line.indexOf('|');
    if (i1 < 0) continue;
    final i2 = line.indexOf('|', i1 + 1);
    if (i2 < 0) continue;
    final type = line.substring(0, i1).toLowerCase();
    final size = int.tryParse(line.substring(i1 + 1, i2).trim()) ?? 0;
    final path = line.substring(i2 + 1);
    final isLink = type.contains('link');
    out.add((
      path: path,
      size: size,
      isDir: !isLink && type.contains('dir'),
      isLink: isLink,
    ));
  }
  return out;
}

/// A node in the tree assembled client-side from [StatEntry] records.
class _TreeNode {
  final String name;
  bool isDir;
  bool isLink = false;

  /// Own size (files/symlinks); ignored for directories, whose [total] is the
  /// sum of their descendants.
  int size = 0;
  int total = 0;
  final Map<String, _TreeNode> children = {};

  _TreeNode(this.name, {this.isDir = false});
}

/// Path of [p] relative to the start point [root] (`''` for the root itself).
String _treeRel(String root, String p) {
  if (p == root) return '';
  if (root == '/') return p.startsWith('/') ? p.substring(1) : p;
  final prefix = root.endsWith('/') ? root : '$root/';
  return p.startsWith(prefix) ? p.substring(prefix.length) : p;
}

/// Renders [entries] (rooted at the start point [root]) as a `tree`-style
/// listing: each line carries the aggregated size, directories are listed
/// first, and subtrees deeper than [maxDepth] are collapsed (their line still
/// reports the full aggregate). `maxDepth == 0` means no depth limit.
List<String> renderTree(
  String root,
  List<StatEntry> entries, {
  required int maxDepth,
}) {
  final rootNode = _TreeNode(root, isDir: true);
  for (final e in entries) {
    final rel = _treeRel(root, e.path);
    if (rel.isEmpty) {
      rootNode.isDir = e.isDir;
      rootNode.isLink = e.isLink;
      rootNode.size = e.size;
      continue;
    }
    final parts = rel.split('/');
    var node = rootNode;
    for (var i = 0; i < parts.length; i++) {
      final seg = parts[i];
      if (seg.isEmpty) continue;
      final leaf = i == parts.length - 1;
      final child = node.children.putIfAbsent(seg, () => _TreeNode(seg));
      if (leaf) {
        child.isDir = e.isDir;
        child.isLink = e.isLink;
        child.size = e.size;
      } else {
        child.isDir = true;
      }
      node = child;
    }
  }
  _treeTotals(rootNode);

  final lines = <String>['$root  [${_fmtBytes(rootNode.total)}]'];
  var dirs = 0;
  var files = 0;
  void walk(_TreeNode node, String prefix, int depth) {
    if (maxDepth != 0 && depth > maxDepth) return;
    final kids = node.children.values.toList()
      ..sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    for (var i = 0; i < kids.length; i++) {
      final k = kids[i];
      final last = i == kids.length - 1;
      final label = k.isLink ? '${k.name} ->' : k.name;
      lines.add(
        '$prefix${last ? '└── ' : '├── '}$label  '
        '[${_fmtBytes(k.total)}]',
      );
      if (k.isDir) {
        dirs++;
      } else {
        files++;
      }
      if (k.isDir && k.children.isNotEmpty) {
        walk(k, '$prefix${last ? '    ' : '│   '}', depth + 1);
      }
    }
  }

  walk(rootNode, '', 1);
  lines
    ..add('')
    ..add(
      '$dirs director${dirs == 1 ? 'y' : 'ies'}, '
      '$files file${files == 1 ? '' : 's'}',
    );
  return lines;
}

/// Post-order pass setting each directory's [total] to the sum of its
/// descendants; files and symlinks keep their own size.
int _treeTotals(_TreeNode n) {
  if (!n.isDir) return n.total = n.size;
  var sum = 0;
  for (final child in n.children.values) {
    sum += _treeTotals(child);
  }
  return n.total = sum;
}

/// Resolves a possibly-relative remote [path] against the live remote cwd.
String _resolveRemote(LocalCommandContext c, String path) {
  if (path.startsWith('/') || path.startsWith('~')) return path;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) return path; // Windows abs
  final cwd = c.currentRemoteCwd?.call();
  if (cwd == null || cwd.isEmpty || cwd == '?') return path;
  final base = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
  return '$base/$path';
}

String _fmtBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

bool _endsWithSep(String p) =>
    p.endsWith('/') || p.endsWith(Platform.pathSeparator);

/// Quotes [s] as a single shell word so it is taken literally on the node.
String _shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// The last path segment of a remote [path] (trailing slashes stripped), used to
/// name a downloaded archive; falls back to `archive` for a root/empty path.
String _remoteBasename(String path) {
  var p = path;
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  final i = p.lastIndexOf('/');
  final base = i < 0 ? p : p.substring(i + 1);
  return base.isEmpty ? 'archive' : base;
}

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
  c.writeLine('  ${pf.entries.length} file(s), ${_fmtBytes(pf.total)} total');
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
    final remote = _resolveRemote(c, positionals.first);
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

    final tx = ClientRuntime(c.client.config);
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
      final probe = await c.client.execute(
        nodeId: nodeId,
        command:
            '[ -d ${_shQuote(remote)} ] && echo d || '
            '{ [ -e ${_shQuote(remote)} ] && echo f || echo n; }',
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
      final res = await c.client.execute(
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
    final defaultName = '${_remoteBasename(remote)}.$ext';
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

    final tx = ClientRuntime(c.client.config);
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
        await c.client.execute(
          nodeId: nodeId,
          command: 'rm -f ${_shQuote(remoteTmp)}',
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
    final remoteDest = _resolveRemote(c, args.length > 1 ? args[1] : '.');
    c.writeLine('Upload: ${File(localPath).absolute.path}  →  $remoteDest');

    final tx = ClientRuntime(c.client.config);
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
      DriveManager.open(c.client);

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

/// Parses a detach timeout like `30m`, `2h`, `1d`, `45s`. Returns `null` for
/// malformed input or an unsupported unit.
Duration? _parseDetachTimeout(String raw) {
  final match = RegExp(
    r'^(\d+)\s*([smhd])$',
  ).firstMatch(raw.trim().toLowerCase());
  if (match == null) return null;
  final n = int.parse(match.group(1)!);
  return switch (match.group(2)!) {
    's' => Duration(seconds: n),
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    'd' => Duration(days: n),
    _ => null,
  };
}

class _DetachCommand extends LocalCommand {
  @override
  String get name => 'detach';
  @override
  String get description =>
      'Detach the session while keeping the remote shell running';
  @override
  String? get usage =>
      ':detach [timeout]\n'
      '    Detach the current session while keeping the remote shell running.\n'
      '    The PTY, shell and child processes stay alive on the node; reconnect\n'
      '    later with `omnyshell sessions resume`.\n'
      '\n'
      '    An optional timeout (units s, m, h, d) expires the session; without\n'
      '    one it stays detached indefinitely.\n'
      '\n'
      '    Examples:\n'
      '      :detach\n'
      '      :detach 1h\n'
      '      :detach 30m';

  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final session = c.session;
    if (session == null || session.id == null) {
      c.writeLine('No active session to detach.');
      return;
    }
    Duration? timeout;
    if (args.isNotEmpty) {
      timeout = _parseDetachTimeout(args.first);
      if (timeout == null) {
        c.writeLine(
          'Invalid timeout "${args.first}". '
          'Use a number with unit s, m, h or d (e.g. 30m, 2h, 1d).',
        );
        return;
      }
    }

    final DetachOutcome outcome;
    try {
      outcome = await session.detach(timeout: timeout);
    } on Object catch (e) {
      c.writeLine('Detach failed: $e');
      return;
    }

    c.writeLine('');
    c.writeLine('Session detached successfully.');
    c.writeLine('');
    c.writeLine('Session ID: ${outcome.shortId}');
    if (outcome.expiresAt != null) {
      c.writeLine('Expires: ${outcome.expiresAt!.toLocal()}');
    }
    c.writeLine('');
    c.writeLine('Resume later using:');
    c.writeLine('');
    c.writeLine(
      '  omnyshell sessions resume ${c.node.id.value} ${outcome.shortId}',
    );
    c.writeLine('');
    c.requestDetach();
  }
}

class _ExitCommand extends LocalCommand {
  @override
  String get name => 'exit';
  @override
  List<String> get aliases => const ['quit'];
  @override
  String get description => 'Close the session and disconnect';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    c.requestExit();
  }
}
