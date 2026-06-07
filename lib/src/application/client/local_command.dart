import '../../domain/auth/principal.dart';
import '../../domain/entities/node_descriptor.dart';
import '../../shared/utils/clock.dart';
import 'client_runtime.dart';
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

  bool _exitRequested = false;

  /// Creates a command context.
  LocalCommandContext({
    required this.client,
    required this.node,
    required this.startedAt,
    required this.writeLine,
    this.principal,
    this.session,
    this.clock = const SystemClock(),
  });

  /// Whether a command requested the session to end.
  bool get exitRequested => _exitRequested;

  /// Requests that the interactive session terminate.
  void requestExit() => _exitRequested = true;
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
    c.writeLine('Local commands:');
    for (final cmd in LocalCommandRegistry.withDefaults().commands) {
      c.writeLine('  :${cmd.name.padRight(14)} ${cmd.description}');
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
    c.writeLine('Node: ${c.node.id.value}');
    c.writeLine('OS: ${c.node.platform.os}');
    c.writeLine('Arch: ${c.node.platform.arch}');
    c.writeLine('Hostname: ${c.node.platform.hostname}');
    c.writeLine('Agent: ${c.node.platform.agentVersion}');
    c.writeLine(
      'Session Duration: '
      '${_formatDuration(c.clock.now().difference(c.startedAt))}',
    );
  }
}

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
  String get description => 'Ping the Hub';
  @override
  Future<void> run(LocalCommandContext c, List<String> args) async {
    final rtt = await c.client.ping();
    c.writeLine('pong ${rtt.inMilliseconds}ms');
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
