import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:omnyshell/omnyshell_node.dart';

Future<void> main(List<String> args) async {
  final runner =
      CommandRunner<void>('omnyshell', 'Secure, Hub-centric remote shell.')
        ..addCommand(HubCommand())
        ..addCommand(NodeCommand())
        ..addCommand(ConnectCommand())
        ..addCommand(ExecCommand())
        ..addCommand(NodesCommand())
        ..addCommand(WhoamiCommand());
  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  } on _CliError catch (e) {
    stderr.writeln('error: ${e.message}');
    exitCode = 1;
  }
}

class _CliError implements Exception {
  final String message;
  _CliError(this.message);
}

// --- Shared option helpers ---------------------------------------------------

void _addConnectionOptions(ArgParser parser) {
  parser
    ..addOption('hub', help: 'Hub wss URL', defaultsTo: 'wss://127.0.0.1:8443')
    ..addOption('principal', abbr: 'u', help: 'Login name')
    ..addOption('token', abbr: 't', help: 'Bearer token')
    ..addOption('key', help: 'Path to a base64 Ed25519 seed file (32 bytes)')
    ..addOption('ca', help: 'Path to the Hub CA/cert PEM to trust');
}

Future<CredentialProvider> _credentialsFrom(ArgResults args) async {
  final principal = args['principal'] as String?;
  if (principal == null || principal.isEmpty) {
    throw _CliError('--principal is required');
  }
  final token = args['token'] as String?;
  final keyPath = args['key'] as String?;
  if (token != null && token.isNotEmpty) {
    return TokenCredentialProvider(principal: principal, token: token);
  }
  if (keyPath != null && keyPath.isNotEmpty) {
    final seed = base64.decode(
      base64.normalize(File(keyPath).readAsStringSync().trim()),
    );
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    return PublicKeyCredentialProvider(principal: principal, keyPair: keyPair);
  }
  throw _CliError('provide --token or --key for authentication');
}

SecurityContext? _trustContext(ArgResults args) {
  final ca = args['ca'] as String?;
  if (ca == null || ca.isEmpty) return null;
  final context = SecurityContext(withTrustedRoots: true);
  context.setTrustedCertificates(ca);
  return context;
}

// --- hub start ---------------------------------------------------------------

class HubCommand extends Command<void> {
  HubCommand() {
    addSubcommand(HubStartCommand());
  }

  @override
  String get name => 'hub';
  @override
  String get description => 'Run and manage a Hub.';
}

class HubStartCommand extends Command<void> {
  HubStartCommand() {
    argParser
      ..addOption('host', defaultsTo: '0.0.0.0', help: 'Bind address')
      ..addOption('port', defaultsTo: '8443', help: 'Listen port')
      ..addOption('cert', help: 'Server certificate chain PEM (required)')
      ..addOption('key', help: 'Server private key PEM (required)')
      ..addOption(
        'authorized-keys',
        help: 'authorized_keys file (principal key roles ...)',
      )
      ..addMultiOption(
        'grant-token',
        help: 'Token grant as "principal:token:role1,role2"',
      );
  }

  @override
  String get name => 'start';
  @override
  String get description => 'Start the Hub (foreground).';

  @override
  Future<void> run() async {
    final args = argResults!;
    final cert = args['cert'] as String?;
    final key = args['key'] as String?;
    if (cert == null || key == null) {
      throw _CliError('--cert and --key are required (no insecure mode)');
    }
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);

    final authenticators = <Authenticator>[];
    final authorizedKeys = args['authorized-keys'] as String?;
    if (authorizedKeys != null && authorizedKeys.isNotEmpty) {
      authenticators.add(
        PublicKeyAuthenticator(
          AuthorizedKeysStore.parse(File(authorizedKeys).readAsStringSync()),
        ),
      );
    }
    final tokens = <String, TokenGrant>{};
    for (final entry in args['grant-token'] as List<String>) {
      final parts = entry.split(':');
      if (parts.length < 2) continue;
      final roles = parts.length >= 3
          ? parts[2].split(',').where((r) => r.isNotEmpty).toSet()
          : <String>{};
      tokens[parts[1]] = TokenGrant(
        principal: PrincipalId(parts[0]),
        roles: roles,
      );
    }
    if (tokens.isNotEmpty) authenticators.add(TokenAuthenticator(tokens));
    if (authenticators.isEmpty) {
      throw _CliError(
        'configure at least one of --authorized-keys or --grant-token',
      );
    }

    final hub = OmnyShellHub(
      HubConfig(
        host: args['host'] as String,
        port: int.parse(args['port'] as String),
        securityContext: context,
        authenticator: authenticators.length == 1
            ? authenticators.single
            : CompositeAuthenticator(authenticators),
        logger: stderr.writeln,
      ),
    );
    await hub.start();
    stdout.writeln(
      'OmnyShell Hub listening on wss://${args['host']}:${hub.port}',
    );
    ProcessSignal.sigint.watch().listen((_) async {
      stdout.writeln('\nShutting down...');
      await hub.stop();
      exit(0);
    });
    await Completer<void>().future; // run until interrupted
  }
}

// --- node start --------------------------------------------------------------

class NodeCommand extends Command<void> {
  NodeCommand() {
    addSubcommand(NodeStartCommand());
  }

  @override
  String get name => 'node';
  @override
  String get description => 'Run and manage a Node.';
}

class NodeStartCommand extends Command<void> {
  NodeStartCommand() {
    _addConnectionOptions(argParser);
    argParser
      ..addOption('id', help: 'Node id (required)')
      ..addOption('name', help: 'Display name')
      ..addMultiOption('label', help: 'Label as key=value')
      ..addOption('shell', help: 'Default shell override');
  }

  @override
  String get name => 'start';
  @override
  String get description => 'Connect this machine to the Hub as a node.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final id = args['id'] as String?;
    if (id == null || id.isEmpty) throw _CliError('--id is required');
    final labels = <String, String>{};
    for (final l in args['label'] as List<String>) {
      final i = l.indexOf('=');
      if (i > 0) labels[l.substring(0, i)] = l.substring(i + 1);
    }

    final node = NodeRuntime(
      NodeConfig(
        hubUri: Uri.parse(args['hub'] as String),
        nodeId: NodeId(id),
        displayName: (args['name'] as String?) ?? id,
        labels: labels,
        credentials: await _credentialsFrom(args),
        backend: ProcessShellBackend(defaultShell: args['shell'] as String?),
        securityContext: _trustContext(args),
        logger: stderr.writeln,
      ),
    );
    await node.connect();
    stdout.writeln('Node "$id" registered and serving sessions.');
    ProcessSignal.sigint.watch().listen((_) async {
      await node.shutdown();
      exit(0);
    });
    await Completer<void>().future;
  }
}

// --- connect (interactive) ---------------------------------------------------

class ConnectCommand extends Command<void> {
  ConnectCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'connect';
  @override
  String get description => 'Open an interactive shell on a node.';

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) throw _CliError('usage: omnyshell connect <node>');
    final nodeId = args.rest.first;
    final client = await _connectClient(args);
    try {
      final nodes = await client.listNodes();
      final descriptor = nodes.firstWhere(
        (n) => n.id.value == nodeId,
        orElse: () => throw _CliError('node not found: $nodeId'),
      );
      final session = await client.openSession(
        nodeId: nodeId,
        mode: SessionMode.shell,
      );
      stdout.writeln('Connected to $nodeId. Type /help for local commands.');

      final registry = LocalCommandRegistry.withDefaults();
      final context = LocalCommandContext(
        client: client,
        node: descriptor,
        principal: client.principal,
        session: session,
        startedAt: DateTime.now(),
        writeLine: stdout.writeln,
      );

      final principal =
          client.principal?.displayName ?? client.principal?.id.value ?? 'user';
      final marker = CwdMarker();
      String? cwd;
      void redraw() =>
          stdout.write(_buildPrompt(principal, nodeId, cwd ?? '?'));

      session.stdout.listen((chunk) {
        final scan = marker.feed(chunk);
        if (scan.output.isNotEmpty) stdout.add(scan.output);
        if (scan.cwd != null) {
          cwd = scan.cwd;
          redraw();
        }
      });
      session.stderr.listen(stderr.add);
      final exitFuture = session.exitCode;

      final stdinSub = stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) async {
            if (registry.isLocalCommand(line)) {
              await registry.handle(line, context);
              if (context.exitRequested) {
                await session.close();
              } else {
                redraw();
              }
            } else {
              session.writeStdin(utf8.encode('$line\n'));
              session.writeStdin(utf8.encode('${marker.command}\n'));
            }
          });

      // Prime the first prompt: report the initial cwd.
      session.writeStdin(utf8.encode('${marker.command}\n'));

      final code = await exitFuture;
      await stdinSub.cancel();
      stdout.writeln('Session closed (exit $code).');
      exitCode = code == -1 ? 0 : code;
    } finally {
      await client.close();
    }
  }
}

/// Builds the interactive prompt line shown before each command.
///
/// Colorizes the `user@node` and path segments when stdout is a TTY (and
/// `NO_COLOR` is unset), otherwise returns a plain prompt.
String _buildPrompt(String principal, String node, String cwd) {
  final color =
      stdout.hasTerminal && !Platform.environment.containsKey('NO_COLOR');
  if (!color) return '$principal@$node:$cwd \$ ';
  const reset = '\u001b[0m';
  const green = '\u001b[32m';
  const blue = '\u001b[34m';
  return '$green$principal@$node$reset:$blue$cwd$reset \$ ';
}

// --- exec --------------------------------------------------------------------

class ExecCommand extends Command<void> {
  ExecCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'exec';
  @override
  String get description => 'Run a command on a node and print its output.';

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.length < 2) {
      throw _CliError('usage: omnyshell exec <node> "<command>"');
    }
    final nodeId = args.rest.first;
    final command = args.rest.sublist(1).join(' ');
    final client = await _connectClient(args);
    try {
      final result = await client.execute(nodeId: nodeId, command: command);
      stdout.write(result.stdoutText);
      stderr.write(result.stderrText);
      exitCode = result.exitCode;
    } finally {
      await client.close();
    }
  }
}

// --- nodes list --------------------------------------------------------------

class NodesCommand extends Command<void> {
  NodesCommand() {
    addSubcommand(NodesListCommand());
  }

  @override
  String get name => 'nodes';
  @override
  String get description => 'Discover nodes.';
}

class NodesListCommand extends Command<void> {
  NodesListCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'list';
  @override
  String get description => 'List nodes visible to you.';

  @override
  Future<void> run() async {
    final client = await _connectClient(argResults!);
    try {
      final nodes = await client.listNodes();
      if (nodes.isEmpty) {
        stdout.writeln('No nodes.');
        return;
      }
      for (final n in nodes) {
        final status = n.online ? 'online' : 'offline';
        stdout.writeln(
          '${n.id.value.padRight(20)} '
          '${n.platform.os}/${n.platform.arch}  [$status]',
        );
      }
    } finally {
      await client.close();
    }
  }
}

// --- whoami ------------------------------------------------------------------

class WhoamiCommand extends Command<void> {
  WhoamiCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'whoami';
  @override
  String get description => 'Show the authenticated principal.';

  @override
  Future<void> run() async {
    final client = await _connectClient(argResults!);
    try {
      final p = client.principal;
      if (p == null) {
        stdout.writeln('Not authenticated.');
        return;
      }
      stdout.writeln('${p.displayName} (${p.id.value})');
      stdout.writeln('Roles: ${(p.roles.toList()..sort()).join(', ')}');
    } finally {
      await client.close();
    }
  }
}

Future<ClientRuntime> _connectClient(ArgResults args) async {
  final client = ClientRuntime(
    ClientConfig(
      hubUri: Uri.parse(args['hub'] as String),
      credentials: await _credentialsFrom(args),
      securityContext: _trustContext(args),
    ),
  );
  await client.connect();
  return client;
}
