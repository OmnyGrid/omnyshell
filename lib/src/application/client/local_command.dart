import 'dart:convert';

import '../../domain/auth/principal.dart';
import '../../domain/backend/shell_family.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../shared/errors/omnyshell_exception.dart';
import '../../shared/utils/clock.dart';
import '../../version.dart';
import 'client_runtime.dart';
import 'remote_path.dart';
import 'remote_session.dart';

/// The captured result of running a command in the host's interactive session
/// (see [LocalCommandContext.runInSession]).
class SessionCommandResult {
  const SessionCommandResult({required this.exitCode, required this.output});

  /// The command's exit code, or `null` if the shell did not report one.
  final int? exitCode;

  /// The command's captured output (stdout + stderr, marker-stripped).
  final String output;
}

/// Runtime context passed to a [LocalCommand].
///
/// Exposes the connected client, the target node's metadata, the live session
/// and a line-oriented output sink. Commands call [requestExit] to end the
/// interactive session.
class LocalCommandContext {
  /// The connected client runtime, or `null` in local mode (`omnyshell local`),
  /// which runs the shell on this machine with no Hub. Commands that genuinely
  /// need a Hub connection read [requireClient]; commands installed in local
  /// mode must not touch the client.
  final ClientRuntime? client;

  /// The node the session is attached to.
  final NodeDescriptor node;

  /// The authenticated principal, if known.
  final Principal? principal;

  /// The active interactive session, if one is open.
  final RemoteSession? session;

  /// The command-language family of the host's shell, used by the AI agent to
  /// pick its command syntax when there is no live [session] to read it from
  /// (notably local mode). `null` falls back to the session's family, then
  /// POSIX.
  final ShellFamily? shellFamily;

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

  /// The registry the command was dispatched from, so `:help` can list the
  /// exact command set the embedder installed (which may include commands beyond
  /// the browser-safe defaults, e.g. the CLI's file-transfer commands). `null`
  /// falls back to the default set.
  final LocalCommandRegistry? registry;

  /// Runs [command] in the host's **current interactive shell session** (with
  /// its PTY, cwd/env and cached credentials), returning its captured output and
  /// exit code. Used by the AI agent so its commands behave like the user typed
  /// them. `null` when the host has no live interactive session to run in (the
  /// web client, non-interactive runs, or non-POSIX shells) — callers then fall
  /// back to a one-off exec.
  final Future<SessionCommandResult> Function(String command)? runInSession;

  /// Registers [handler] to run when the user presses Ctrl-C while this command
  /// is executing (e.g. so the AI agent can offer to abort), or clears it with
  /// `null`. The host only invokes the handler when no remote command is in
  /// flight (otherwise Ctrl-C interrupts that command). `null` when the host has
  /// no interrupt channel.
  final void Function(void Function()? handler)? onInterruptRequest;

  /// Returns a horizontal-rule string sized to the terminal, for commands that
  /// frame their output (e.g. the AI agent brackets its run with a rule).
  /// `null` when the host does not provide one.
  final String Function()? horizontalRule;

  /// Runs [body] with exclusive ownership of the terminal for a full-screen
  /// takeover (e.g. the `:ide` TUI's alternate-screen UI): the host pauses its
  /// line editor and forwards raw input bytes to [body] via the stream it
  /// receives, so [body] reads keystrokes and paints the whole screen, then the
  /// prompt is restored when [body] returns. [body] must read from the provided
  /// stream rather than `stdin` directly (stdin is single-subscription and is
  /// already owned by the host). `null` when the host cannot grant exclusive
  /// terminal access (the web client, non-interactive runs); commands that need
  /// it should report that they require an interactive terminal.
  final Future<void> Function(
    Future<void> Function(Stream<List<int>> input) body,
  )?
  runFullScreen;

  bool _exitRequested = false;
  bool _detachRequested = false;

  /// Creates a command context.
  LocalCommandContext({
    required this.node,
    required this.startedAt,
    required this.writeLine,
    this.client,
    this.principal,
    this.session,
    this.shellFamily,
    this.clock = const SystemClock(),
    this.readLine,
    this.currentRemoteCwd,
    this.printAbove,
    this.registry,
    this.runInSession,
    this.onInterruptRequest,
    this.horizontalRule,
    this.runFullScreen,
  });

  /// The connected client, or throws when the context has none (local mode).
  /// Used by commands that require a Hub connection; those commands are never
  /// installed in local mode, so this never throws in practice.
  ClientRuntime get requireClient =>
      client ?? (throw StateError('this command requires a Hub connection'));

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

  /// Releases any resources the command holds (e.g. an HTTP client / open
  /// sockets), so they do not keep the process alive after the session ends.
  /// Called by [LocalCommandRegistry.dispose]; the default is a no-op.
  Future<void> dispose() async {}
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

  /// Creates a registry pre-populated with the browser-safe built-in commands
  /// (`:help`, `:info`, `:tree`, `:tunnel`, …).
  ///
  /// File-transfer commands that need local filesystem access (`:download`,
  /// `:upload`, `:drive`) are NOT included here so this registry compiles to
  /// JavaScript for the web client; native embedders add them with
  /// `LocalCommandRegistry.withDefaults()..addFileTransferCommands()` (see the
  /// `FileTransferCommands` extension in `file_transfer_commands.dart`).
  factory LocalCommandRegistry.withDefaults() {
    final registry = LocalCommandRegistry();
    for (final command in _builtIns) {
      registry.register(command);
    }
    return registry;
  }

  /// Creates a registry with the subset of built-ins that need no Hub
  /// connection, for local mode (`omnyshell local`).
  ///
  /// Omits the commands that require a connected client or live remote session
  /// (`:latency`, `:ping`, `:tunnel`, `:tree`, `:detach`); the rest read only
  /// the (synthetic) node descriptor and local state. Native local embedders add
  /// the AI command with `..addAiCommand()` but NOT the file-transfer commands
  /// (those operate against a remote node).
  factory LocalCommandRegistry.withLocalDefaults() {
    final registry = LocalCommandRegistry();
    for (final command in _localBuiltIns) {
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

  /// Disposes every registered command (de-duplicated), releasing resources
  /// such as open HTTP clients/sockets so they cannot keep the process alive
  /// after the interactive session ends. Errors from individual commands are
  /// ignored so one failure does not block the rest.
  Future<void> dispose() async {
    for (final command in commands) {
      try {
        await command.dispose();
      } catch (_) {}
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
    _DetachCommand(),
    _ClearCommand(),
    _ExitCommand(),
  ];

  /// The Hub-free subset of [_builtIns] installed by [withLocalDefaults].
  static final List<LocalCommand> _localBuiltIns = [
    _HelpCommand(),
    _InfoCommand(),
    _WhoamiCommand(),
    _OsCommand(),
    _ArchCommand(),
    _HostCommand(),
    _NodeCommand(),
    _CapabilitiesCommand(),
    _SessionCommand(),
    _ClearCommand(),
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
    // List the commands actually installed on the dispatching registry (so an
    // embedder's extra commands show up); fall back to the default set.
    final commands =
        (c.registry ?? LocalCommandRegistry.withDefaults()).commands;
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
    final client = c.client;
    if (client != null) c.writeLine('Hub: ${client.config.hubUri}');
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
    final rtt = await c.requireClient.ping();
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
      final ms = (await c.requireClient.ping()).inMilliseconds;
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
      final t = await c.requireClient.openTunnel(
        nodeId: c.node.id.value,
        targetPort: targetPort,
        publicPort: publicPort,
        secure: secure,
      );
      final host = t.publicHost.isEmpty
          ? c.requireClient.config.hubUri.host
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
      final tunnels = await c.requireClient.listTunnels();
      final mine = tunnels.where((t) => t.nodeId == c.node.id.value).toList();
      if (mine.isEmpty) {
        c.writeLine('No tunnels on ${c.node.id.value}.');
        return;
      }
      for (final t in mine) {
        final host = t.publicHost.isEmpty
            ? c.requireClient.config.hubUri.host
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
      final res = await c.requireClient.closeTunnel(args.first);
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

    var remote = resolveRemotePath(
      path ?? '.',
      cwd: c.currentRemoteCwd?.call(),
    );
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
    final base = remoteBasename(remote);
    final rootHidden = base.startsWith('.') && base != '.' && base != '..';
    final prune = !all && !rootHidden;
    final find = prune
        ? "find ${shQuote(remote)} \\( -name '.?*' -prune \\) -o "
              '-exec $statCmd {} +'
        : 'find ${shQuote(remote)} -exec $statCmd {} +';

    final ExecResult res;
    try {
      res = await c.requireClient.execute(
        nodeId: c.node.id.value,
        command: find,
      );
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

  final lines = <String>['$root  [${formatBytes(rootNode.total)}]'];
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
        '[${formatBytes(k.total)}]',
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

class _ClearCommand extends LocalCommand {
  @override
  String get name => 'clear';
  @override
  String get description => 'Clear the terminal screen and scrollback';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    // Erase the screen (2J) and scrollback (3J), then home the cursor (H).
    c.writeLine('\x1b[2J\x1b[3J\x1b[H');
  }
}
