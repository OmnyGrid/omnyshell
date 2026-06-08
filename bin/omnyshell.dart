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
        ..addCommand(LoginCommand())
        ..addCommand(LogoutCommand())
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

/// The OmnyShell CLI version (kept in sync with `pubspec.yaml`).
const String _omnyShellVersion = '0.3.0';

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

SecurityContext? _trustContext(ArgResults args) =>
    _trustContextFromCa(args['ca'] as String?);

SecurityContext? _trustContextFromCa(String? ca) {
  if (ca == null || ca.isEmpty) return null;
  final context = SecurityContext(withTrustedRoots: true);
  context.setTrustedCertificates(ca);
  return context;
}

/// A resolved Hub connection: where to connect, how to authenticate, and which
/// CA to trust.
typedef _Connection = ({
  Uri hubUri,
  CredentialProvider credentials,
  SecurityContext? security,
});

/// Whether [args] carries explicit credentials on the command line.
bool _hasExplicitCredentials(ArgResults args) {
  final principal = args['principal'] as String?;
  if (principal == null || principal.isEmpty) return false;
  final token = args['token'] as String?;
  final key = args['key'] as String?;
  return (token != null && token.isNotEmpty) || (key != null && key.isNotEmpty);
}

/// Resolves the Hub URL for [args]: an explicit `--hub` wins, otherwise the
/// saved default Hub, otherwise the built-in default.
Uri _resolveHubUri(ArgResults args, CredentialStore store) {
  if (args.wasParsed('hub')) return Uri.parse(args['hub'] as String);
  return Uri.parse(store.defaultHub ?? args['hub'] as String);
}

/// Resolves how to connect a client command: explicit credential flags take
/// precedence, otherwise the saved session for the target Hub is used.
Future<_Connection> _resolveConnection(ArgResults args) async {
  final store = await CredentialStore.load();
  final hubUri = _resolveHubUri(args, store);

  if (_hasExplicitCredentials(args)) {
    return (
      hubUri: hubUri,
      credentials: await _credentialsFrom(args),
      security: _trustContext(args),
    );
  }

  final session = store.sessions[hubUri.toString()];
  if (session == null) {
    throw _CliError(
      'not logged in to $hubUri — run: '
      'omnyshell login --hub $hubUri --principal <user> --token <token>',
    );
  }
  final ca = (args['ca'] as String?) ?? session.ca;
  return (
    hubUri: hubUri,
    credentials: await session.toCredentialProvider(),
    security: _trustContextFromCa(ca),
  );
}

// --- login -------------------------------------------------------------------

class LoginCommand extends Command<void> {
  LoginCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'login';
  @override
  String get description =>
      'Authenticate to a Hub and save the session for later commands.';

  @override
  Future<void> run() async {
    final args = argResults!;
    if (!_hasExplicitCredentials(args)) {
      throw _CliError('provide --principal and --token (or --key) to log in');
    }
    final credentials = await _credentialsFrom(args);
    final hubUri = Uri.parse(args['hub'] as String);
    final ca = args['ca'] as String?;

    // Validate the credentials by performing the real auth handshake.
    final client = ClientRuntime(
      ClientConfig(
        hubUri: hubUri,
        credentials: credentials,
        securityContext: _trustContextFromCa(ca),
      ),
    );
    try {
      await client.connect();
    } on Object catch (e) {
      throw _CliError('login failed: $e');
    } finally {
      await client.close();
    }

    final principal = args['principal'] as String;
    final token = args['token'] as String?;
    final keyPath = args['key'] as String?;
    final session = (token != null && token.isNotEmpty)
        ? StoredSession.token(principal: principal, token: token, ca: ca)
        : StoredSession.publicKey(
            principal: principal,
            keyPath: File(keyPath!).absolute.path,
            ca: ca,
          );

    final store = await CredentialStore.load();
    store.sessions[hubUri.toString()] = session;
    store.defaultHub = hubUri.toString();
    await store.save();

    stdout.writeln('Logged in to $hubUri as $principal.');
  }
}

// --- logout ------------------------------------------------------------------

class LogoutCommand extends Command<void> {
  LogoutCommand() {
    argParser
      ..addOption('hub', help: 'Hub wss URL to log out of')
      ..addFlag('all', negatable: false, help: 'Remove every saved session.');
  }

  @override
  String get name => 'logout';
  @override
  String get description => 'Remove a saved Hub session.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final store = await CredentialStore.load();

    if (args['all'] as bool) {
      if (store.sessions.isEmpty) {
        stdout.writeln('No saved sessions.');
        return;
      }
      final count = store.sessions.length;
      store.sessions.clear();
      store.defaultHub = null;
      await store.save();
      stdout.writeln('Removed $count saved session(s).');
      return;
    }

    final hub = args.wasParsed('hub')
        ? args['hub'] as String
        : store.defaultHub;
    if (hub == null) {
      throw _CliError('not logged in to any Hub (use --hub or --all)');
    }
    if (store.sessions.remove(hub) == null) {
      throw _CliError('no saved session for $hub');
    }
    if (store.defaultHub == hub) {
      store.defaultHub = store.sessions.keys.isEmpty
          ? null
          : store.sessions.keys.first;
    }
    await store.save();
    stdout.writeln('Logged out of $hub.');
  }
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
        identityCertificate: File(cert).readAsBytesSync(),
        authenticator: authenticators.length == 1
            ? authenticators.single
            : CompositeAuthenticator(authenticators),
        logger: stderr.writeln,
      ),
    );
    await hub.start();
    if (hub.uid != null) stdout.writeln('Hub UID: ${hub.uid}');
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
      ..addOption('shell', help: 'Default shell override')
      ..addOption(
        'pty-backend',
        allowed: ['script', 'native', 'none'],
        defaultsTo: 'script',
        help:
            'PTY backend for interactive shells:\n'
            '"script" (default) uses the system script(1) utility — no native '
            'lib, no live resize;\n'
            '"native" uses portable_pty (FFI) — supports live resize but is '
            'temporarily deprecated (intermittent native crash);\n'
            '"none" disables the PTY (pipe shell with env-var geometry).',
      );
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

    final shell = args['shell'] as String?;
    final pipe = ProcessShellBackend(defaultShell: shell);
    final ShellBackend backend;
    switch (args['pty-backend'] as String) {
      case 'native':
        // Opt-in to the deprecated portable_pty (FFI) backend for live resize.
        // ignore: deprecated_member_use_from_same_package
        backend = PtyShellBackend(
          defaultShell: shell,
          fallback: pipe,
          onWarning: stderr.writeln,
        );
      case 'none':
        backend = pipe;
      default: // 'script'
        backend = ScriptPtyShellBackend(
          defaultShell: shell,
          fallback: pipe,
          onWarning: stderr.writeln,
        );
    }

    final node = NodeRuntime(
      NodeConfig(
        hubUri: Uri.parse(args['hub'] as String),
        nodeId: NodeId(id),
        displayName: (args['name'] as String?) ?? id,
        labels: labels,
        credentials: await _credentialsFrom(args),
        backend: backend,
        securityContext: _trustContext(args),
        logger: stderr.writeln,
      ),
    );
    await node.connect();
    if (node.uid != null) stdout.writeln('Node UID: ${node.uid}');
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
      // Advertise the local terminal's type and geometry so the node can
      // allocate a PTY at the right size (full terminal apps like `nano` then
      // fill the window); falls back to env-var geometry on nodes without a PTY.
      final pty = stdout.hasTerminal
          ? PtySpec(
              term: Platform.environment['TERM'] ?? 'xterm-256color',
              cols: stdout.terminalColumns,
              rows: stdout.terminalLines,
            )
          : null;
      final session = await client.openSession(
        nodeId: nodeId,
        mode: SessionMode.shell,
        pty: pty,
      );

      // Forward live terminal resizes to the remote PTY (POSIX only).
      StreamSubscription<ProcessSignal>? winch;
      if (pty != null && !Platform.isWindows) {
        winch = ProcessSignal.sigwinch.watch().listen((_) {
          if (stdout.hasTerminal) {
            session.resize(
              cols: stdout.terminalColumns,
              rows: stdout.terminalLines,
            );
          }
        });
      }

      Duration? latency;
      try {
        latency = await client.ping();
      } catch (_) {
        latency = null;
      }
      stdout.writeln(
        _buildWelcome(
          node: descriptor,
          principal: client.principal,
          hubUri: client.config.hubUri,
          session: session,
          latency: latency,
          width: stdout.hasTerminal ? stdout.terminalColumns.clamp(40, 72) : 60,
          color: _colorEnabled(),
        ),
      );

      final registry = LocalCommandRegistry.withDefaults();
      final principal =
          client.principal?.displayName ?? client.principal?.id.value ?? 'user';
      final marker = CwdMarker();
      // Detects when a full-screen remote app (nano/vim/top) takes over the
      // alternate screen, so the editor can switch to raw passthrough.
      final screen = ScreenModeDetector();
      String? cwd;
      String? branch;
      String? gitStatus;
      String? privilege;
      // When a local command (e.g. :download) asks the user a question, the next
      // committed line is routed to this completer instead of to the remote
      // shell (and is excluded from history).
      Completer<String>? pendingLine;

      // History is scoped per node UID + user so distinct connections never
      // mix; a UID change is detected, reported, and (optionally) migrated.
      final interactive = stdin.hasTerminal;
      final history = await _loadNodeHistory(
        principal: principal,
        nodeId: nodeId,
        nodeUid: descriptor.uid,
        interactive: interactive,
      );
      late final LineEditor editor;

      void redraw() => editor.setPrompt(
        _buildPrompt(
          principal,
          nodeId,
          cwd ?? '?',
          branch: branch,
          gitStatus: gitStatus,
          privilege: privilege,
        ),
      );

      final context = LocalCommandContext(
        client: client,
        node: descriptor,
        principal: client.principal,
        session: session,
        startedAt: DateTime.now(),
        writeLine: stdout.writeln,
        readLine: (prompt) {
          final completer = Completer<String>();
          pendingLine = completer;
          editor.setPrompt(prompt);
          return completer.future;
        },
        currentRemoteCwd: () => cwd,
      );

      session.stdout.listen((chunk) {
        // Watch the raw stream for alternate-screen transitions and flip the
        // editor between line editing and raw passthrough accordingly.
        if (screen.feed(chunk)) {
          editor.setPassthrough(screen.inAltScreen);
          // Repaint the prompt once the app has released the screen.
          if (!screen.inAltScreen) redraw();
        }
        final scan = marker.feed(chunk);
        if (scan.output.isNotEmpty) stdout.add(scan.output);
        if (scan.cwd != null) {
          cwd = scan.cwd;
          branch = scan.branch;
          gitStatus = scan.gitStatus;
          privilege = scan.privilege;
          // A marker only runs back at the shell prompt; if we somehow missed
          // the alternate-screen exit, recover line-editing mode now.
          if (screen.inAltScreen) {
            screen.reset();
            editor.setPassthrough(false);
          }
          redraw();
        }
      });
      session.stderr.listen(stderr.add);
      final exitFuture = session.exitCode;

      editor = LineEditor(
        input: stdin,
        output: stdout.write,
        history: history,
        interactive: interactive,
        setRawMode: (raw) {
          // Some terminals (or non-TTY stdin) reject mode changes; ignore.
          try {
            stdin.echoMode = !raw;
            stdin.lineMode = !raw;
          } on Object {
            // Leave the terminal in whatever mode it already had.
          }
        },
        onInterrupt: redraw,
        onEof: () => session.close(),
        onRaw: (bytes) => session.writeStdin(bytes),
        onLine: (line) async {
          // A command is waiting on user input (e.g. a confirmation prompt).
          final waiting = pendingLine;
          if (waiting != null) {
            pendingLine = null;
            waiting.complete(line);
            return;
          }
          if (line.isNotEmpty) await editor.addHistory(line);
          if (registry.isLocalCommand(line)) {
            await registry.handle(line, context);
            if (context.exitRequested) {
              await session.close();
            } else {
              redraw();
            }
          } else {
            // Run the command and the cwd marker as one logical line so the
            // shell consumes both before executing: a foreground app (nano,
            // vim, less…) then never reads the marker as input, and the marker
            // runs right after the command/app exits to refresh the prompt.
            // `eval '<cmd>'` keeps this valid for any command (pipes, trailing
            // `&`, `cd`) where a bare `<cmd> ; <marker>` would be a syntax error.
            final escaped = line.replaceAll("'", r"'\''");
            session.writeStdin(
              utf8.encode("eval '$escaped' ; ${marker.command}\n"),
            );
          }
        },
      );
      editor.start();

      // Prime the first prompt: report the initial cwd.
      session.writeStdin(utf8.encode('${marker.command}\n'));

      final code = await exitFuture;
      await winch?.cancel();
      await editor.close();
      stdout.writeln('Session closed (exit $code).');
      exitCode = code == -1 ? 0 : code;
    } finally {
      await client.close();
    }
  }
}

/// Loads the command history for an interactive session, scoped per connecting
/// [principal] and the node's [nodeUid].
///
/// The last-seen UID for the `<principal>@<nodeId>` connection target is tracked
/// in a [UidStore] under `~/.omnyshell/node-uids/`. When the node reports a UID
/// that differs from the previously recorded one, the user is alerted: in an
/// [interactive] session they are prompted to migrate the prior UID's history
/// into the new UID's history; a non-interactive session migrates automatically.
/// The old history file is always left intact as a backup.
///
/// When the node reports no UID, history falls back to the legacy
/// `<principal>@<nodeId>` key with no tracking.
Future<CommandHistory> _loadNodeHistory({
  required String principal,
  required String nodeId,
  required OmnyUid? nodeUid,
  required bool interactive,
}) async {
  if (nodeUid == null) {
    return CommandHistory.load(key: '$principal@$nodeId');
  }

  final newKey = '$principal@${nodeUid.value}';
  final sep = Platform.pathSeparator;
  final store = UidStore(
    fileName:
        'node-uids$sep${CommandHistory.sanitizeKey('$principal@$nodeId')}.uid',
  );

  UidResolution res;
  try {
    res = await store.resolve(nodeUid);
  } on Object {
    // A failure tracking the UID must never block the session.
    return CommandHistory.load(key: newKey);
  }

  final previous = res.previous;
  if (res.changed && previous != null) {
    stdout.writeln(
      '⚠ Node "$nodeId" UID changed: ${previous.value} -> ${nodeUid.value}',
    );
    stdout.writeln('  Command history is now tracked under the new UID.');
    var migrate = true; // non-interactive sessions migrate automatically
    if (interactive) {
      stdout.write('  Migrate previous command history to the new UID? [y/N] ');
      final answer = stdin.readLineSync()?.trim().toLowerCase() ?? '';
      migrate = answer == 'y' || answer == 'yes';
    }
    if (migrate) {
      await CommandHistory.migrate(
        fromKey: '$principal@${previous.value}',
        toKey: newKey,
      );
      stdout.writeln('  Previous history migrated.');
    }
  }

  return CommandHistory.load(key: newKey);
}

/// Builds the interactive prompt line shown before each command.
///
/// Format: `user@node:cwd git(branch +S ~M ?U) (⚠ root) $`. The `git(...)`
/// segment appears only when [branch] is set (a git-managed remote cwd), with
/// the `+S ~M ?U` counts shown only when [gitStatus] is non-empty. The
/// `(⚠ privilege)` segment appears only when [privilege] is set (superuser).
///
/// Colorizes segments when stdout is a TTY (and `NO_COLOR` is unset), otherwise
/// returns a plain prompt: `user@node` green, `cwd` cyan, the git segment blue
/// with a red branch and green status counts, and the privilege warning bold red.
String _buildPrompt(
  String principal,
  String node,
  String cwd, {
  String? branch,
  String? gitStatus,
  String? privilege,
}) {
  final esc = String.fromCharCode(27);
  final red = '$esc[31m';
  final boldRed = '$esc[1;31m';
  final counts = gitStatus != null && gitStatus.isNotEmpty ? ' $gitStatus' : '';
  if (!_colorEnabled()) {
    final git = branch == null ? '' : ' git($branch$counts)';
    final priv = privilege == null ? '' : ' (⚠ $privilege)';
    return '$principal@$node:$cwd$git$priv \$ ';
  }
  const reset = '\u001b[0m';
  const green = '\u001b[32m';
  const blue = '\u001b[34m';
  const cyan = '\u001b[36m';
  final coloredCounts = counts.isEmpty ? '' : '$green$counts$red';
  final git = branch == null
      ? ''
      : ' ${blue}git($red$branch$coloredCounts$reset$blue)$reset';
  final priv = privilege == null ? '' : ' $boldRed(⚠ $privilege)$reset';
  return '$green$principal@$node$reset:$cyan$cwd$reset$git$priv \$ ';
}

/// Whether ANSI colors should be emitted: only on a TTY with `NO_COLOR` unset.
bool _colorEnabled() =>
    stdout.hasTerminal && !Platform.environment.containsKey('NO_COLOR');

/// Builds the multi-line welcome banner shown after connecting to a node.
///
/// Rule-separated layout: a header line with the node id and online status, a
/// details block (node, platform, capabilities, labels, user, Hub, latency,
/// session), and the local-commands hint — fenced by full-width rules. Pure:
/// all values are passed in so the result is deterministic and testable.
String _buildWelcome({
  required NodeDescriptor node,
  required Principal? principal,
  required Uri hubUri,
  required RemoteSession session,
  required Duration? latency,
  required int width,
  required bool color,
}) {
  const reset = '\u001b[0m';
  const green = '\u001b[32m';
  const red = '\u001b[31m';
  const dim = '\u001b[2m';
  String paint(String code, String text) => color ? '$code$text$reset' : text;

  final rule = paint(dim, '─' * width);
  final dot = paint(node.online ? green : red, '●');
  final status = node.online ? 'online' : 'offline';

  final lines = <String>[];
  void row(String label, String value) =>
      lines.add(' ${label.padRight(10)} $value');

  lines.add(rule);
  lines.add(
    ' ${paint(green, 'OmnyShell')} ${paint(dim, 'v$_omnyShellVersion')} · '
    'connected to ${paint(green, node.id.value)}   $dot $status',
  );
  lines.add(rule);

  final displayName = node.displayName.isEmpty
      ? node.id.value
      : '${node.id.value} (${node.displayName})';
  row('Node', displayName);
  if (node.uid != null) row('UID', node.uid!.value);
  row(
    'Platform',
    '${node.platform.os}/${node.platform.arch} · ${node.platform.hostname}',
  );
  row('Agent', node.platform.agentVersion);

  final caps = node.capabilities;
  if (caps != null) {
    if (caps.shells.isNotEmpty) row('Shells', caps.shells.join(', '));
    if (caps.features.isNotEmpty) row('Features', caps.features.join(', '));
    row('Sessions', 'max ${caps.maxSessions}');
  }

  if (node.labels.isNotEmpty) {
    row(
      'Labels',
      node.labels.entries.map((e) => '${e.key}=${e.value}').join(', '),
    );
  }

  final p = principal;
  if (p != null) {
    final roles = (p.roles.toList()..sort()).join(', ');
    final who = '${p.displayName} (${p.id.value})';
    row('User', roles.isEmpty ? who : '$who · $roles');
  } else {
    row('User', 'user');
  }

  row('Hub', hubUri.toString());
  row('Latency', latency == null ? 'n/a' : '${latency.inMilliseconds}ms');
  row('Session', '${session.id?.value ?? '(pending)'} · ${session.mode.name}');

  lines.add(rule);
  lines.add(' Type :help for local commands.');
  lines.add(rule);

  return lines.join('\n');
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
  final connection = await _resolveConnection(args);
  final client = ClientRuntime(
    ClientConfig(
      hubUri: connection.hubUri,
      credentials: connection.credentials,
      securityContext: connection.security,
    ),
  );
  await client.connect();
  return client;
}
