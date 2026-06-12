import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dart_service_manager/dart_service_manager.dart' as svc;
import 'package:omnydrive/omnydrive.dart' show SyncDirection;
import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:omnyshell/omnyshell_node.dart';

Future<void> main(List<String> args) async {
  final runner =
      CommandRunner<void>(
          'omnyshell',
          'OmnyShell v$omnyShellVersion — Secure, Hub-centric remote shell.',
        )
        ..argParser.addFlag(
          'version',
          abbr: 'V',
          negatable: false,
          help: 'Print the omnyshell version and exit.',
        )
        ..addCommand(LoginCommand())
        ..addCommand(LogoutCommand())
        ..addCommand(HubCommand())
        ..addCommand(NodeCommand())
        ..addCommand(ServiceCommand())
        ..addCommand(CertCommand())
        ..addCommand(ConnectCommand())
        ..addCommand(ExecCommand())
        ..addCommand(RunCommand())
        ..addCommand(DriveCommand())
        ..addCommand(NodesCommand())
        ..addCommand(SessionsCommand())
        ..addCommand(TunnelCommand())
        ..addCommand(WhoamiCommand());
  try {
    if (runner.parse(args)['version'] as bool) {
      stdout.writeln('omnyshell $omnyShellVersion');
      return;
    }
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

void _addConnectionOptions(ArgParser parser, {bool includeKey = true}) {
  parser
    ..addOption('hub', help: 'Hub wss URL', defaultsTo: 'wss://127.0.0.1:8443')
    ..addOption('principal', abbr: 'u', help: 'Login name')
    ..addOption('token', abbr: 't', help: 'Bearer token');
  if (includeKey) {
    parser.addOption(
      'key',
      help: 'Path to a base64 Ed25519 seed file (32 bytes)',
    );
  }
  parser
    ..addOption('ca', help: 'Path to the Hub CA/cert PEM to trust')
    ..addFlag(
      'insecure-skip-verify',
      negatable: false,
      help:
          'Skip TLS verification (trusts any cert, ignores hostname '
          'mismatch). Insecure — for self-signed/dev hubs only.',
    );
}

/// The mount-lifecycle options shared by `exec` (when `--mount` is used) and
/// `run`. They let a command mount a local directory onto the node, run inside
/// it, and sync the node's modifications back to local afterwards.
void _addExecMountOptions(ArgParser parser, {bool includeMount = true}) {
  parser.addOption(
    'cwd',
    abbr: 'C',
    help: 'Working directory for the remote command.',
  );
  if (includeMount) {
    parser.addOption(
      'mount',
      help:
          'Local directory to mount on the node before running, then sync back.',
    );
  }
  parser
    ..addOption(
      'mount-path',
      help: 'Remote path to mount to (default: an ephemeral path on the node).',
    )
    ..addOption(
      'mount-name',
      help: 'Mount name (defaults to the local directory name).',
    )
    ..addFlag(
      'initial-sync',
      defaultsTo: true,
      help: 'Push the local directory to the node before running.',
    )
    ..addOption(
      'sync-interval',
      defaultsTo: '0',
      help:
          'Seconds between periodic sync-backs while running (0 = only at end).',
    )
    ..addFlag(
      'unmount',
      negatable: false,
      help: 'Tear the mount down after the run (default: keep it registered).',
    )
    ..addFlag(
      'clean-remote',
      negatable: false,
      help: 'On --unmount, also delete the remote mounted files.',
    );
}

/// The Hub `start` options, shared by `hub start` and `service install hub`.
void _addHubOptions(ArgParser parser, {bool includeKey = true}) {
  parser
    ..addOption('host', defaultsTo: '0.0.0.0', help: 'Bind address')
    ..addOption('port', defaultsTo: '8443', help: 'Listen port')
    ..addOption('cert', help: 'Server certificate chain PEM (required)');
  if (includeKey) {
    parser.addOption('key', help: 'Server private key PEM (required)');
  }
  parser
    ..addOption(
      'authorized-keys',
      help: 'authorized_keys file (principal key roles ...)',
    )
    ..addMultiOption(
      'grant-token',
      help: 'Token grant as "principal:token:role1,role2"',
    )
    ..addOption(
      'tunnel-port-range',
      help:
          'Public TCP port range tunnels may bind, e.g. 20000-20100 '
          '(omit to disable tunneling). Align with firewall rules.',
    )
    ..addOption(
      'tunnel-public-host',
      help:
          'Host advertised to clients for tunnel public ports '
          '(default: the hub host).',
    );
}

/// The Node-specific `start` options (beyond the shared connection options),
/// shared by `node start` and `service install node`.
void _addNodeExtraOptions(ArgParser parser) {
  parser
    ..addOption('id', help: 'Node id (required)')
    ..addOption('name', help: 'Display name')
    ..addMultiOption('label', help: 'Label as key=value')
    ..addOption('shell', help: 'Default shell override')
    ..addOption(
      'profile',
      help:
          'Path to the node env profile (default ~/.omnyshell/profile.yaml). '
          'Its env (notably PATH) is applied to every session.',
    )
    ..addFlag(
      'no-profile-sync',
      negatable: false,
      help:
          'Do not derive PATH from your shell rc on an interactive start; use '
          'the existing profile as-is.',
    )
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

/// The union of Hub and Node `start` options for `service install`/`reconfigure`,
/// which must parse either role. `key` is shared (Hub private key PEM or Node
/// seed file) so it is registered exactly once here.
void _addServiceRoleOptions(ArgParser parser) {
  parser.addOption(
    'key',
    help: 'Hub private key PEM, or Node base64 Ed25519 seed file (32 bytes)',
  );
  _addHubOptions(parser, includeKey: false);
  _addConnectionOptions(parser, includeKey: false);
  _addNodeExtraOptions(parser);
}

/// Validates that [args] carries the flags a Hub needs to start.
void _validateHubArgs(ArgResults args) {
  if ((args['cert'] as String?) == null || (args['key'] as String?) == null) {
    throw _CliError('--cert and --key are required (no insecure mode)');
  }
  final hasAuth =
      ((args['authorized-keys'] as String?)?.isNotEmpty ?? false) ||
      (args['grant-token'] as List<String>).isNotEmpty;
  if (!hasAuth) {
    throw _CliError(
      'configure at least one of --authorized-keys or --grant-token',
    );
  }
}

/// Validates that [args] carries the flags a Node needs to start.
void _validateNodeArgs(ArgResults args) {
  final id = args['id'] as String?;
  if (id == null || id.isEmpty) throw _CliError('--id is required');
  if (!_hasExplicitCredentials(args)) {
    throw _CliError('provide --principal and --token (or --key) for the node');
  }
}

/// Appends `--name value` to [out] when [value] is non-empty.
void _emitOption(List<String> out, String name, Object? value) {
  if (value == null) return;
  final s = value.toString();
  if (s.isEmpty) return;
  out
    ..add('--$name')
    ..add(s);
}

/// Like [_emitOption] but resolves a path-valued option to an absolute path, so
/// the installed service finds it regardless of working directory.
void _emitPathOption(List<String> out, String name, Object? value) {
  if (value == null) return;
  final s = value.toString();
  if (s.isEmpty) return;
  out
    ..add('--$name')
    ..add(File(s).absolute.path);
}

/// Appends `--name value` for each entry of a multi-option.
void _emitMultiOption(List<String> out, String name, List<String> values) {
  for (final v in values) {
    out
      ..add('--$name')
      ..add(v);
  }
}

/// Reconstructs the `omnyshell <role> start …` argument vector from [args],
/// absolutizing path-valued options so the baked-in service command is portable.
List<String> _serviceStartArgs(String role, ArgResults args) {
  final out = <String>[role, 'start'];
  if (role == 'hub') {
    _emitOption(out, 'host', args['host']);
    _emitOption(out, 'port', args['port']);
    _emitPathOption(out, 'cert', args['cert']);
    _emitPathOption(out, 'key', args['key']);
    _emitPathOption(out, 'authorized-keys', args['authorized-keys']);
    _emitMultiOption(out, 'grant-token', args['grant-token'] as List<String>);
    _emitOption(out, 'tunnel-port-range', args['tunnel-port-range']);
    _emitOption(out, 'tunnel-public-host', args['tunnel-public-host']);
  } else {
    _emitOption(out, 'hub', args['hub']);
    _emitOption(out, 'principal', args['principal']);
    _emitOption(out, 'token', args['token']);
    _emitPathOption(out, 'key', args['key']);
    _emitPathOption(out, 'ca', args['ca']);
    if (args['insecure-skip-verify'] as bool? ?? false) {
      out.add('--insecure-skip-verify');
    }
    _emitOption(out, 'id', args['id']);
    _emitOption(out, 'name', args['name']);
    _emitMultiOption(out, 'label', args['label'] as List<String>);
    _emitOption(out, 'shell', args['shell']);
    _emitOption(out, 'pty-backend', args['pty-backend']);
  }
  return out;
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

/// Returns a callback that accepts any TLS certificate when
/// `--insecure-skip-verify` is set, otherwise null (standard verification).
/// Warns on stderr when active.
bool Function(X509Certificate, String, int)? _insecureBadCertCallback(
  ArgResults args,
) => _insecureCallback(args['insecure-skip-verify'] as bool? ?? false);

/// Returns an accept-any-certificate callback (with a stderr warning) when
/// [insecure] is true, otherwise null (standard verification). [insecure] may
/// come from the `--insecure-skip-verify` flag or a remembered login session.
bool Function(X509Certificate, String, int)? _insecureCallback(bool insecure) {
  if (!insecure) return null;
  stderr.writeln(
    '[security] WARNING: TLS certificate and hostname verification are '
    'DISABLED (insecure-skip-verify). Connection is vulnerable to MITM. '
    'Use only for trusted self-signed/dev hubs.',
  );
  return (_, _, _) => true;
}

/// Asks whether to persist `--insecure-skip-verify` for [hubUri] on the saved
/// session. Returns false without prompting when there is no TTY (the safer
/// default), so future commands verify normally unless the flag is re-passed.
bool _confirmRememberInsecure(Uri hubUri) {
  if (!(stdin.hasTerminal && stdout.hasTerminal)) {
    stderr.writeln(
      'note: not storing --insecure-skip-verify (no TTY to confirm); pass it '
      'again on future commands to $hubUri, or re-run login interactively.',
    );
    return false;
  }
  stdout.write(
    'Store --insecure-skip-verify so future commands to $hubUri also skip TLS '
    'verification? [y/N] ',
  );
  final answer = stdin.readLineSync()?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

/// A resolved Hub connection: where to connect, how to authenticate, and which
/// CA to trust.
typedef _Connection = ({
  Uri hubUri,
  CredentialProvider credentials,
  SecurityContext? security,
  bool Function(X509Certificate, String, int)? onBadCertificate,
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
      onBadCertificate: _insecureBadCertCallback(args),
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
  final insecure =
      (args['insecure-skip-verify'] as bool? ?? false) ||
      session.insecureSkipVerify;
  return (
    hubUri: hubUri,
    credentials: await session.toCredentialProvider(),
    security: _trustContextFromCa(ca),
    onBadCertificate: _insecureCallback(insecure),
  );
}

/// Formats one or more example invocations into a help footer that the `args`
/// package appends to a command's `--help` output via [Command.usageFooter].
String _usageExamples(List<String> examples) =>
    'Examples:\n${examples.map((e) => '  $e').join('\n')}';

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
  String? get usageFooter => _usageExamples([
    'omnyshell login --hub wss://hub.example.com:8443 --principal alice --token s3cr3t',
    'omnyshell login --hub wss://hub.example.com:8443 --principal alice --key ./alice.seed',
  ]);

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
        onBadCertificate: _insecureBadCertCallback(args),
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

    // If the login skipped TLS verification, ask whether to remember that so
    // future commands reusing this session also skip it (otherwise they would
    // verify normally and fail against the same untrusted cert).
    final usedInsecure = args['insecure-skip-verify'] as bool? ?? false;
    final rememberInsecure = usedInsecure && _confirmRememberInsecure(hubUri);

    final session = (token != null && token.isNotEmpty)
        ? StoredSession.token(
            principal: principal,
            token: token,
            ca: ca,
            insecureSkipVerify: rememberInsecure,
          )
        : StoredSession.publicKey(
            principal: principal,
            keyPath: File(keyPath!).absolute.path,
            ca: ca,
            insecureSkipVerify: rememberInsecure,
          );

    final store = await CredentialStore.load();
    store.sessions[hubUri.toString()] = session;
    store.defaultHub = hubUri.toString();
    await store.save();

    stdout.writeln('Logged in to $hubUri as $principal.');
    if (rememberInsecure) {
      stdout.writeln(
        'Stored --insecure-skip-verify for this session; future commands to '
        '$hubUri will skip TLS verification.',
      );
    }
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
  String? get usageFooter => _usageExamples([
    'omnyshell logout',
    'omnyshell logout --hub wss://hub.example.com:8443',
  ]);

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

// --- cert gen ----------------------------------------------------------------

class CertCommand extends Command<void> {
  CertCommand() {
    addSubcommand(CertGenCommand());
  }

  @override
  String get name => 'cert';

  @override
  String get description => 'Generate and manage TLS certificates.';
}

class CertGenCommand extends Command<void> {
  CertGenCommand() {
    argParser
      ..addOption('out', defaultsTo: 'certs', help: 'Output directory')
      ..addMultiOption('host', help: 'Extra SAN hostname (repeatable)')
      ..addOption('cn', defaultsTo: 'localhost', help: 'Server certificate CN')
      ..addOption(
        'days',
        defaultsTo: '825',
        help: 'Server cert validity (days)',
      )
      ..addOption('ca-days', defaultsTo: '3650', help: 'CA validity (days)')
      ..addFlag('force', help: 'Overwrite existing certificates');
  }

  @override
  String get name => 'gen';

  @override
  String get description =>
      'Generate a CA + Hub server certificate '
      '(ca.crt/ca.key/server.crt/server.key).';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell cert gen --out certs --host hub.example.com',
    'omnyshell cert gen --cn hub.example.com --days 365 --force',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    final GeneratedCertificates out;
    try {
      out = await CertGenerator.generate(
        outputDir: args['out'] as String,
        hosts: args['host'] as List<String>,
        commonName: args['cn'] as String,
        serverDays: int.parse(args['days'] as String),
        caDays: int.parse(args['ca-days'] as String),
        force: args['force'] as bool,
      );
    } on CertGeneratorException catch (e) {
      throw _CliError(e.message);
    }

    stdout
      ..writeln('Certificates written:')
      ..writeln('  ${out.serverCert}  (hub start --cert)')
      ..writeln('  ${out.serverKey}  (hub start --key)')
      ..writeln('  ${out.caCert}  (client/node --ca)')
      ..writeln()
      ..writeln('Start the Hub:')
      ..writeln('  omnyshell hub start \\')
      ..writeln('    --host 127.0.0.1 --port 8443 \\')
      ..writeln('    --cert ${out.serverCert} --key ${out.serverKey} \\')
      ..writeln('    --grant-token "alice:s3cr3t:admin"');
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
    _addHubOptions(argParser);
  }

  @override
  String get name => 'start';

  @override
  String get description => 'Start the Hub (foreground).';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell hub start --cert certs/server.crt --key certs/server.key --grant-token "alice:s3cr3t:admin"',
    'omnyshell hub start --host 0.0.0.0 --port 8443 --authorized-keys ./authorized_keys --tunnel-port-range 20000-20100',
  ]);

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

    final rangeRaw = args['tunnel-port-range'] as String?;
    PortRange? tunnelRange;
    if (rangeRaw != null && rangeRaw.isNotEmpty) {
      try {
        tunnelRange = PortRange.parse(rangeRaw);
      } on Object catch (e) {
        throw _CliError('invalid --tunnel-port-range "$rangeRaw": $e');
      }
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
        tunnelPortRange: tunnelRange,
        tunnelPublicHost: (args['tunnel-public-host'] as String?) ?? '',
        logger: stderr.writeln,
      ),
    );
    stderr.writeln('OmnyShell Hub v$omnyShellVersion starting...');
    await hub.start();
    if (hub.uid != null) stdout.writeln('Hub UID: ${hub.uid}');
    stdout.writeln(
      'OmnyShell Hub listening on wss://${args['host']}:${hub.port}',
    );
    stdout.writeln(
      tunnelRange == null
          ? 'Tunnels: disabled (set --tunnel-port-range to enable)'
          : 'Tunnels: enabled (public ports $tunnelRange)',
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
    addSubcommand(NodeProfileCommand());
  }

  @override
  String get name => 'node';

  @override
  String get description => 'Run and manage a Node.';
}

/// Resolves the shell whose rc the profile sync reads (and sessions run):
/// `--shell` override, else `$SHELL` (`%COMSPEC%` on Windows).
String _resolveNodeShell(String? override) {
  if (override != null && override.trim().isNotEmpty) return override;
  if (Platform.isWindows) {
    return Platform.environment['COMSPEC'] ?? 'cmd.exe';
  }
  final shell = Platform.environment['SHELL'];
  return (shell != null && shell.trim().isNotEmpty) ? shell : '/bin/sh';
}

/// Resolves the node user's home directory — preferring the profile's `HOME`,
/// then the node process environment — used as the default working directory of
/// new sessions. Returns `null` when it cannot be resolved or does not exist, so
/// sessions fall back to the node's own cwd.
String? _resolveNodeHome(Map<String, String> env) {
  final home =
      env['HOME'] ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (home == null || home.trim().isEmpty) return null;
  return Directory(home).existsSync() ? home : null;
}

/// On an interactive (TTY) start, offers to refresh the profile PATH from the
/// operator's shell rc; on a non-interactive start, prints a one-line hint and
/// leaves the profile untouched.
Future<void> _maybeSyncNodeProfile({
  required String profilePath,
  required String shell,
  required bool disabled,
}) async {
  if (disabled || Platform.isWindows) return;
  final interactive = stdin.hasTerminal && stdout.hasTerminal;
  if (!interactive) {
    stderr.writeln(
      "hint: run 'omnyshell node profile sync' to load PATH from "
      '${rcFileFor(shell)}',
    );
    return;
  }
  await _runProfileSync(
    profilePath: profilePath,
    shell: shell,
    assumeYes: false,
    quietWhenUnchanged: true,
    // The start flow re-loads the profile right after, so no restart is needed.
    reportRestart: false,
  );
}

/// Captures the rc PATH and, when it differs from the stored profile, shows the
/// change and (unless [assumeYes]) prompts before writing `profile.yaml`.
Future<void> _runProfileSync({
  required String profilePath,
  required String shell,
  required bool assumeYes,
  bool quietWhenUnchanged = false,
  bool reportRestart = true,
}) async {
  final rawCaptured = await captureLoginPath(shell: shell);
  if (rawCaptured == null) {
    if (!quietWhenUnchanged) {
      stderr.writeln('Could not capture PATH from $shell.');
    }
    return;
  }
  // Drop any duplicate entries so the exported profile PATH stays unique.
  final captured = uniquePath(rawCaptured);

  final current = NodeProfile.load(path: profilePath).env['PATH'];
  final diff = pathDiff(current, captured);
  if (!diff.changed) {
    if (!quietWhenUnchanged) stdout.writeln('Node PATH already up to date.');
    return;
  }

  stdout.writeln(
    'Detected PATH from your shell profile (${rcFileFor(shell)}):',
  );
  for (final entry in diff.added) {
    stdout.writeln('  + $entry');
  }
  for (final entry in diff.removed) {
    stdout.writeln('  - $entry');
  }

  if (!assumeYes) {
    stdout.write('Update $profilePath? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') {
      stdout.writeln('Skipped; profile unchanged.');
      return;
    }
  }

  NodeProfile.writePath(profilePath, captured);
  stdout.writeln('Updated $profilePath');
  if (reportRestart) {
    stdout.writeln(
      'Restart the node ("omnyshell node start") for the new PATH to '
      'take effect.',
    );
  }
}

/// `omnyshell node profile …` — manage the node env profile.
class NodeProfileCommand extends Command<void> {
  NodeProfileCommand() {
    addSubcommand(NodeProfileSyncCommand());
  }

  @override
  String get name => 'profile';

  @override
  String get description =>
      'Manage the node env profile (~/.omnyshell/profile.yaml).';
}

/// `omnyshell node profile sync` — refresh the profile PATH from the shell rc.
class NodeProfileSyncCommand extends Command<void> {
  NodeProfileSyncCommand() {
    argParser
      ..addOption('shell', help: 'Shell whose rc to read (default \$SHELL)')
      ..addOption(
        'profile',
        help: 'Profile path (default ~/.omnyshell/profile.yaml)',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Write without prompting for confirmation.',
      );
  }

  @override
  String get name => 'sync';

  @override
  String get description =>
      'Derive PATH from your shell rc and write it to the node profile.';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell node profile sync',
    'omnyshell node profile sync --shell zsh -y',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    await _runProfileSync(
      profilePath: (args['profile'] as String?) ?? NodeProfile.defaultPath(),
      shell: _resolveNodeShell(args['shell'] as String?),
      assumeYes: args['yes'] as bool,
    );
  }
}

class NodeStartCommand extends Command<void> {
  NodeStartCommand() {
    _addConnectionOptions(argParser);
    _addNodeExtraOptions(argParser);
  }

  @override
  String get name => 'start';

  @override
  String get description => 'Connect this machine to the Hub as a node.';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell node start --id web-01',
    'omnyshell node start --id web-01 --name "Web 01" --label region=eu',
  ]);

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

    // Derive PATH from the operator's shell rc and apply the profile env to
    // every session (sessions run rc-less, so PATH would otherwise be bare).
    final profilePath =
        (args['profile'] as String?) ?? NodeProfile.defaultPath();
    await _maybeSyncNodeProfile(
      profilePath: profilePath,
      shell: _resolveNodeShell(shell),
      disabled: args['no-profile-sync'] as bool,
    );
    final env = NodeProfile.load(path: profilePath).env;

    // New sessions start in the user's home directory (like `cd ~`) instead of
    // wherever the node was launched. An explicit per-request cwd still wins.
    final home = _resolveNodeHome(env);

    final pipe = ProcessShellBackend(
      defaultShell: shell,
      baseEnvironment: env,
      workingDirectory: home,
    );
    final ShellBackend backend;
    switch (args['pty-backend'] as String) {
      case 'native':
        // Opt-in to the deprecated portable_pty (FFI) backend for live resize.
        // ignore: deprecated_member_use_from_same_package
        // backend = PtyShellBackend(
        //   defaultShell: shell,
        //   fallback: pipe,
        //   onWarning: stderr.writeln,
        // );
        throw UnsupportedError("PtyShellBackend disabled!");
      case 'none':
        backend = pipe;
      default: // 'script'
        backend = ScriptPtyShellBackend(
          defaultShell: shell,
          fallback: pipe,
          baseEnvironment: env,
          workingDirectory: home,
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
        onBadCertificate: _insecureBadCertCallback(args),
        logger: stderr.writeln,
      ),
    );
    stderr.writeln('OmnyShell Node v$omnyShellVersion ("$id") starting...');
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

// --- service (install Hub/Node as an OS service) ------------------------------

/// The Dart package name dart_service_manager records these services under.
const _servicePackage = 'omnyshell';

/// The installable service roles; the role is a positional argument.
const _serviceRoles = {'hub', 'node'};

/// DEC private-mode reset emitted when an interactive session ends, restoring
/// the local terminal after a full-screen remote program (vim, claude…) may
/// have enabled modes it did not clean up. Undoes alt-screen (1049), hidden
/// cursor (25) and SGR attributes (0m), every mouse-tracking mode (1000/1002/
/// 1003 trackers, 1005/1006/1015 encodings) — leaving these on spews `ESC[<…M`
/// reports on every mouse move — and bracketed paste (2004).
const _terminalModeReset =
    '\x1b[?1049l\x1b[?25h\x1b[0m'
    '\x1b[?1000l\x1b[?1002l\x1b[?1003l'
    '\x1b[?1005l\x1b[?1006l\x1b[?1015l'
    '\x1b[?2004l';

/// Reads and validates the `hub|node` role positional from [args].
String _requireRole(ArgResults args) {
  final rest = args.rest;
  if (rest.isEmpty) throw _CliError('specify a role: hub or node');
  final role = rest.first;
  if (!_serviceRoles.contains(role)) {
    throw _CliError("unknown role '$role' (expected: hub or node)");
  }
  if (rest.length > 1) {
    throw _CliError('unexpected arguments: ${rest.skip(1).join(' ')}');
  }
  return role;
}

/// Runs a dart_service_manager [action], translating its exceptions into the
/// CLI's `_CliError` for a clean message.
Future<void> _runService(Future<void> Function() action) async {
  try {
    await action();
  } on svc.ServiceAlreadyInstalledException catch (e) {
    throw _CliError(e.message);
  } on svc.PermissionDeniedException catch (e) {
    throw _CliError('${e.message} (try again with elevated privileges)');
  } on svc.ServiceManagerException catch (e) {
    throw _CliError(e.message);
  }
}

/// Runs a [WindowsTaskService] action, translating its exception into the CLI's
/// `_CliError` (with an elevation hint on access-denied).
Future<void> _runWindowsTask(Future<void> Function() action) async {
  try {
    await action();
  } on WindowsTaskException catch (e) {
    throw _CliError(
      e.permissionDenied
          ? '${e.message} (try again from an elevated Administrator prompt)'
          : e.message,
    );
  }
}

svc.DartServiceManager _serviceManager({bool verbose = false}) =>
    svc.DartServiceManager.forCurrentPlatform(
      logger: svc.ConsoleServiceLogger(
        minLevel: verbose ? svc.LogLevel.debug : svc.LogLevel.info,
      ),
    );

/// Adds the `--verbose` flag shared by every `service` subcommand, surfacing the
/// service manager's debug-level logging.
void _addVerboseFlag(ArgParser parser) {
  parser.addFlag(
    'verbose',
    abbr: 'v',
    negatable: false,
    help: 'Show debug-level service manager logging.',
  );
}

class ServiceCommand extends Command<void> {
  ServiceCommand() {
    addSubcommand(ServiceInstallCommand());
    addSubcommand(ServiceUninstallCommand());
    addSubcommand(ServiceStartCommand());
    addSubcommand(ServiceStopCommand());
    addSubcommand(ServiceRestartCommand());
    addSubcommand(ServiceStatusCommand());
    addSubcommand(ServiceReconfigureCommand());
  }

  @override
  String get name => 'service';

  @override
  String get description =>
      'Install and manage the Hub or Node as an OS service.';
}

/// Builds the descriptor that installs *this* omnyshell executable to run
/// `omnyshell <role> start …` with the flags captured from [args].
svc.ServiceDescriptor _serviceDescriptor(String role, ArgResults args) {
  if (role == 'hub') {
    _validateHubArgs(args);
  } else {
    _validateNodeArgs(args);
  }
  final scope = (args['system'] as bool)
      ? svc.ServiceScope.system
      : svc.ServiceScope.user;
  final env = <String, String>{};
  final dataDir = args['data-dir'] as String?;
  if (dataDir != null && dataDir.isNotEmpty) {
    env['OMNYSHELL_HOME'] = Directory(dataDir).absolute.path;
  } else if (scope == svc.ServiceScope.system) {
    env['OMNYSHELL_HOME'] = '/var/lib/omnyshell';
  }
  return svc.ServiceDescriptor.forCurrentExecutable(
    packageName: _servicePackage,
    serviceName: role,
    arguments: _serviceStartArgs(role, args),
    environment: env,
    scope: scope,
    restart: svc.RestartPolicy.always,
  );
}

/// Adds the options shared by `service install` and `service reconfigure`.
void _addServiceConfigOptions(ArgParser parser) {
  _addServiceRoleOptions(parser);
  _addVerboseFlag(parser);
  parser
    ..addFlag(
      'system',
      negatable: false,
      help: 'Install machine-wide (requires elevated privileges).',
    )
    ..addOption(
      'data-dir',
      help:
          'OMNYSHELL_HOME for the service to store state/UIDs. '
          'Defaults to /var/lib/omnyshell under --system.',
    );
}

class ServiceInstallCommand extends Command<void> {
  ServiceInstallCommand() {
    _addServiceConfigOptions(argParser);
    argParser
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the rendered service definition without installing.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace an existing service of the same role.',
      );
  }

  @override
  String get name => 'install';

  @override
  String get description => 'Install the Hub or Node as an OS service.';

  @override
  String get invocation => 'omnyshell service install <hub|node> [options]';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell service install node --id web-01',
    'omnyshell service install hub --cert certs/server.crt --key certs/server.key --grant-token "alice:s3cr3t:admin"',
    'omnyshell service install node --id web-01 --dry-run',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    final role = _requireRole(args);
    final descriptor = _serviceDescriptor(role, args);
    // Windows runs through Task Scheduler, not the SCM: a plain Dart console app
    // cannot do the SCM start handshake and the SCM kills it with error 1053.
    if (Platform.isWindows) {
      final task = WindowsTaskService();
      if (args['dry-run'] as bool) {
        stdout.writeln(task.render(descriptor));
        return;
      }
      await _runWindowsTask(() async {
        await task.install(
          descriptor,
          startNow: true,
          force: args['force'] as bool,
        );
        stdout.writeln(
          'Installed and started "$role" via Task Scheduler '
          '(${descriptor.scope.name} scope).',
        );
      });
      return;
    }
    final manager = _serviceManager(verbose: args['verbose'] as bool);
    if (args['dry-run'] as bool) {
      stdout.writeln(manager.renderDefinition(descriptor));
      return;
    }
    await _runService(() async {
      await manager.installDescriptor(
        descriptor,
        startNow: true,
        force: args['force'] as bool,
      );
      stdout.writeln(
        'Installed and started service "$role" (${descriptor.scope.name} '
        'scope).',
      );
    });
  }
}

class ServiceReconfigureCommand extends Command<void> {
  ServiceReconfigureCommand() {
    _addServiceConfigOptions(argParser);
  }

  @override
  String get name => 'reconfigure';

  @override
  String get description =>
      'Re-apply changed flags to an installed Hub/Node service.';

  @override
  String get invocation => 'omnyshell service reconfigure <hub|node> [options]';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell service reconfigure node --id web-01 --label region=eu',
    'omnyshell service reconfigure hub --tunnel-port-range 20000-20100',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    final role = _requireRole(args);
    final descriptor = _serviceDescriptor(role, args);
    if (Platform.isWindows) {
      await _runWindowsTask(() async {
        await WindowsTaskService().install(
          descriptor,
          startNow: false,
          force: true,
        );
        stdout.writeln('Reconfigured "$role" (Task Scheduler).');
      });
      return;
    }
    await _runService(() async {
      await _serviceManager(
        verbose: args['verbose'] as bool,
      ).reconfigure(descriptor);
      stdout.writeln('Reconfigured service "$role".');
    });
  }
}

/// Base for the lifecycle subcommands that take only a `hub|node` role.
abstract class _ServiceRoleCommand extends Command<void> {
  _ServiceRoleCommand() {
    _addVerboseFlag(argParser);
  }

  @override
  String get invocation => 'omnyshell service $name <hub|node>';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell service $name node',
    'omnyshell service $name hub',
  ]);

  /// Performs the action against the SCM/systemd/launchd backend.
  Future<void> act(svc.DartServiceManager manager, String role);

  /// Performs the action against the Windows Task Scheduler backend.
  Future<void> actWindows(WindowsTaskService task, String role);

  @override
  Future<void> run() async {
    final args = argResults!;
    final role = _requireRole(args);
    if (Platform.isWindows) {
      await _runWindowsTask(() => actWindows(WindowsTaskService(), role));
      return;
    }
    await _runService(
      () => act(_serviceManager(verbose: args['verbose'] as bool), role),
    );
  }
}

class ServiceUninstallCommand extends _ServiceRoleCommand {
  @override
  String get name => 'uninstall';

  @override
  String get description => 'Stop and remove the Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    await manager.uninstall(_servicePackage, serviceName: role);
    stdout.writeln('Uninstalled service "$role".');
  }

  @override
  Future<void> actWindows(WindowsTaskService task, String role) async {
    await task.uninstall(role);
    stdout.writeln('Uninstalled "$role".');
  }
}

class ServiceStartCommand extends _ServiceRoleCommand {
  @override
  String get name => 'start';

  @override
  String get description => 'Start the installed Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    await manager.start(_servicePackage, role);
    stdout.writeln('Started service "$role".');
  }

  @override
  Future<void> actWindows(WindowsTaskService task, String role) async {
    await task.start(role);
    stdout.writeln('Started "$role".');
  }
}

class ServiceStopCommand extends _ServiceRoleCommand {
  @override
  String get name => 'stop';

  @override
  String get description => 'Stop the installed Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    await manager.stop(_servicePackage, role);
    stdout.writeln('Stopped service "$role".');
  }

  @override
  Future<void> actWindows(WindowsTaskService task, String role) async {
    await task.stop(role);
    stdout.writeln('Stopped "$role".');
  }
}

class ServiceRestartCommand extends _ServiceRoleCommand {
  @override
  String get name => 'restart';

  @override
  String get description => 'Restart the installed Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    await manager.restart(_servicePackage, role);
    stdout.writeln('Restarted service "$role".');
  }

  @override
  Future<void> actWindows(WindowsTaskService task, String role) async {
    await task.restart(role);
    stdout.writeln('Restarted "$role".');
  }
}

class ServiceStatusCommand extends _ServiceRoleCommand {
  @override
  String get name => 'status';

  @override
  String get description => 'Show the status of the Hub/Node service.';

  @override
  Future<void> act(svc.DartServiceManager manager, String role) async {
    final status = await manager.status(_servicePackage, role);
    stdout.writeln('$role: ${status.name}');
  }

  @override
  Future<void> actWindows(WindowsTaskService task, String role) async {
    stdout.writeln('$role: ${await task.status(role)}');
  }
}

// --- connect (interactive) ---------------------------------------------------

/// Translates the Enter key to a carriage return for raw passthrough to remote
/// full-screen apps.
///
/// Dart's raw mode disables `ICANON`/`ECHO` but not `ICRNL`, so the local
/// terminal delivers the Enter key as LF (`0x0a`). Remote apps in their own raw
/// mode — and especially their prompts (e.g. nano's "File Name to Write"
/// confirmation) — expect the CR (`0x0d`) that a real terminal or `ssh` sends,
/// and ignore a bare LF. Map LF to CR (collapsing any CRLF to a single CR) so
/// Enter is recognised everywhere. Only keystrokes (passthrough input) pass
/// through here; remote output is untouched.
List<int> _enterToCarriageReturn(List<int> bytes) {
  if (!bytes.contains(0x0a)) return bytes;
  final out = <int>[];
  for (final b in bytes) {
    if (b == 0x0a) {
      if (out.isNotEmpty && out.last == 0x0d) continue; // CRLF → CR
      out.add(0x0d);
    } else {
      out.add(b);
    }
  }
  return out;
}

class ConnectCommand extends Command<void> {
  ConnectCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'connect';

  @override
  String get description => 'Open an interactive shell on a node.';

  @override
  String? get usageFooter => _usageExamples(['omnyshell connect web-01']);

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

      exitCode = await _runInteractiveSession(
        client: client,
        descriptor: descriptor,
        session: session,
        nodeId: nodeId,
        pty: pty,
      );
    } finally {
      await client.close();
    }
  }
}

/// Drives the interactive line-editor loop over an open shell [session] (used by
/// both `connect` and `sessions resume`). Returns the process exit code, or `0`
/// if the session was detached. Does not close [client] — the caller owns it.
Future<int> _runInteractiveSession({
  required ClientRuntime client,
  required NodeDescriptor descriptor,
  required RemoteSession session,
  required String nodeId,
  required PtySpec? pty,
  bool resumedInAltScreen = false,
}) async {
  {
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
        width: _terminalWidth(),
        color: _colorEnabled(),
      ),
    );

    final registry = LocalCommandRegistry.withDefaults();
    final principal =
        client.principal?.displayName ?? client.principal?.id.value ?? 'user';
    // Seed the prompt-completion marker from the stable session id so a resumed
    // client derives the *same* token the original connect used. Otherwise the
    // marker queued behind a running full-screen program (with the original
    // token) is never recognized, and exiting the program leaves no prompt.
    final marker = CwdMarker(session.id?.value);
    // The remote shell's command language (POSIX, PowerShell, or cmd) decides
    // the marker/command syntax we send. The node reported it on session-open.
    final dialect = ShellDialect.forFamily(session.shellFamily);
    String? cwd;
    String? branch;
    String? gitStatus;
    String? privilege;
    // True from the moment a remote command is dispatched until its completion
    // marker returns. While set, the remote program owns the terminal: the
    // editor is in raw passthrough and the local prompt is not drawn. The
    // marker — not any guess from the command text — is the authoritative
    // signal for when the shell is back at its (idle) prompt.
    var inFlight = false;
    // One-shot: after resuming into a full-screen program, the resumed client
    // never primed its cwd. When that program exits, fetch the cwd once so the
    // restored prompt isn't drawn as `?`.
    var pendingResumeCwd = resumedInAltScreen;

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

    // Forward Ctrl-C to the remote: interrupt the running command (the remote
    // shell survives via its INT trap). Invoked both by the SIGINT handler
    // (the terminal keeps ISIG on, so Ctrl-C arrives as a signal, not a byte)
    // and by the line editor's 0x03 path on platforms that deliver the byte.
    void interruptRemote() {
      session.interrupt();
      // While a command is in flight its trailing marker (which runs after the
      // interrupted command, since the shell survives) drives the repaint, so
      // do nothing here. At idle the editor just cleared its line on Ctrl-C, so
      // repaint the prompt — no marker round-trip is needed as nothing ran.
      if (!inFlight) redraw();
    }

    final context = LocalCommandContext(
      client: client,
      node: descriptor,
      principal: client.principal,
      session: session,
      startedAt: DateTime.now(),
      writeLine: stdout.writeln,
      // Only offer interactive prompts when there is a terminal to read from;
      // non-interactive sessions auto-proceed (the confirm hook treats a null
      // readLine as "yes").
      readLine: interactive ? (prompt) => editor.prompt(prompt) : null,
      currentRemoteCwd: () => cwd,
      // Background output (e.g. `:drive watch`) repaints around the input line
      // using the same print-above path as the session's stdout listener.
      printAbove: (line) => editor.printAbove(() => stdout.writeln(line)),
    );

    final stdoutSub = session.stdout.listen((chunk) {
      // Once detached, drop any output still buffered in the channel: writing it
      // (and the prompt repaint printAbove performs) would smear escape
      // sequences onto the local terminal after the session is already gone.
      if (session.wasDetached) return;
      // Replenish the node's send window for the bytes we just consumed.
      // Without this the channel's 256 KiB credit drains and output stalls
      // permanently — a full-screen TUI that repaints on every scroll (e.g.
      // claude's plan view) hits the limit within a handful of redraws.
      if (chunk.isNotEmpty) session.grantWindow(chunk.length);
      final scan = marker.feed(chunk);
      // Emit output without disturbing the input line: while a command is in
      // flight the editor is in passthrough (the program owns the screen) so
      // this writes the bytes raw; at idle (e.g. a backgrounded job printing)
      // it erases and repaints the prompt around the output.
      editor.printAbove(() {
        if (scan.output.isNotEmpty) stdout.add(scan.output);
      });
      // A full marker carries fresh cwd/git state; adopt it before redrawing.
      if (scan.cwd != null) {
        cwd = scan.cwd;
        branch = scan.branch;
        gitStatus = scan.gitStatus;
        privilege = scan.privilege;
      }
      // Any marker (full or ping) means the command finished and the shell is
      // back at its prompt: the command no longer owns the terminal, so leave
      // passthrough and repaint the prompt after its output.
      if (scan.completed) {
        inFlight = false;
        editor.setPassthrough(false);
        if (pendingResumeCwd && cwd == null) {
          // Resumed full-screen program just exited and we still don't know the
          // cwd: fetch it once (we're safely back at the shell prompt). The
          // prompt repaints when this marker completes with a non-null cwd.
          pendingResumeCwd = false;
          session.writeStdin(utf8.encode('${dialect.fullMarker(marker)}\n'));
        } else {
          redraw();
        }
      }
    });
    final stderrSub = session.stderr.listen((chunk) {
      if (session.wasDetached) return;
      if (chunk.isNotEmpty) session.grantWindow(chunk.length);
      stderr.add(chunk);
    });
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
      onInterrupt: interruptRemote,
      onEof: () => session.close(),
      onRaw: (bytes) => session.writeStdin(_enterToCarriageReturn(bytes)),
      onComplete: (word, isCommand) async {
        // Skip completion while a command owns the terminal. (Tab only reaches
        // here in line mode anyway; the editor also suppresses completion while
        // a prompt is awaiting an answer.)
        if (inFlight) {
          return const <String>[];
        }
        try {
          // Run the candidate generator as a one-off exec in the session's
          // current directory, so relative-path completion is correct.
          final result = await client
              .execute(
                nodeId: nodeId,
                command: remoteCompletionCommand(word, isCommand: isCommand),
                cwd: cwd,
              )
              .timeout(const Duration(seconds: 4));
          final candidates = utf8
              .decode(result.stdout, allowMalformed: true)
              .split('\n')
              .map((s) => s.trimRight())
              .where((s) => s.isNotEmpty)
              .toList();
          // Cap the list so a huge directory cannot flood the terminal.
          return candidates.length > 200
              ? candidates.sublist(0, 200)
              : candidates;
        } on Object {
          return const <String>[]; // completion is best-effort
        }
      },
      onLine: (line) async {
        if (line.isNotEmpty) await editor.addHistory(line);
        if (registry.isLocalCommand(line)) {
          await registry.handle(line, context);
          if (context.exitRequested) {
            // `:detach` already parked the session server-side and tore down
            // the local channel; closing it would kill the remote shell, so
            // only close on a real `:exit`/`:quit`.
            if (!context.detachRequested) await session.close();
          } else {
            redraw();
          }
        } else if (line.trim().isEmpty) {
          // Blank line: nothing to run remotely; just repaint the prompt on
          // the fresh row (no marker round-trip, no output to wait for).
          redraw();
        } else {
          // Hand the terminal to the remote for the duration of the command:
          // switch to raw passthrough so every keystroke (including Enter)
          // reaches the program rather than being committed as a local line
          // (which would inject the marker into its stdin), and so the local
          // prompt is not redrawn over the program's output. The completion
          // marker (handled in the stdout listener) ends the handover. This
          // covers full-screen apps and interactive line-readers uniformly,
          // without guessing from the command text.
          inFlight = true;
          if (interactive) editor.setPassthrough(true);
          // Run the command and a marker as one logical line so the shell
          // consumes both before executing: a foreground app (nano, vim, less…)
          // then never reads the marker as input, and the marker runs right
          // after the command/app exits — signalling completion so the prompt
          // repaints in the right place (after the output). `eval '<cmd>'`
          // keeps this valid for any command (pipes, trailing `&`, `cd`) where
          // a bare `<cmd> ; <marker>` would be a syntax error. Read-only
          // commands cannot change cwd/git state, so use the lightweight ping
          // marker (no `git` queries) instead of the full one.
          // Read-only commands cannot change cwd/git state, so use the
          // lightweight ping marker (no `git` queries) instead of the full one.
          final tail = mayChangeCwdOrGit(line)
              ? dialect.fullMarker(marker)
              : dialect.pingMarker(marker);
          // The dialect runs the command and the marker as one logical line so a
          // foreground app consumes both, the marker fires right after it exits,
          // and (on POSIX) terminal echo is toggled around cooked-mode readers.
          final cmd = dialect.wrapCommand(
            line,
            interactive: interactive,
            tail: tail,
          );
          session.writeStdin(utf8.encode('$cmd\n'));
        }
      },
    );
    editor.start();

    // Resuming into a full-screen program: attach in passthrough with a command
    // already "in flight", so keystrokes reach the program and no local prompt
    // is drawn. The replayed output (delivered on the next event-loop turn,
    // after the editor is fully started) repaints the program; its already-
    // queued completion marker leaves passthrough and restores the prompt when
    // the program exits.
    if (resumedInAltScreen) {
      inFlight = true;
      if (interactive) editor.setPassthrough(true);
    }

    // Intercept Ctrl-C at the process level (interactive sessions only). Raw
    // mode (lineMode=false) clears ICANON but not ISIG, so the terminal still
    // raises SIGINT on Ctrl-C — which would otherwise terminate omnyshell
    // before any byte reaches the editor. Catching it both keeps omnyshell
    // alive and lets us relay the interrupt to the remote (discarding the
    // local line first in line mode). Non-interactive runs keep the default
    // (terminate) so a scripted session can still be killed with Ctrl-C.
    StreamSubscription<ProcessSignal>? sigint;
    if (interactive) {
      sigint = ProcessSignal.sigint.watch().listen((_) => editor.interrupt());
    }

    // Run the dialect's one-time setup (POSIX: a no-op INT trap so Ctrl-C
    // interrupts the foreground command without killing the non-interactive
    // shell; Windows: prompt suppression). Skipped when resuming into a
    // full-screen program: the shell is already set up, and writing these lines
    // would type them into the program.
    if (!resumedInAltScreen) {
      final init = dialect.initLine;
      if (init != null) session.writeStdin(utf8.encode('$init\n'));
      // Prime the first prompt: report the initial cwd.
      session.writeStdin(utf8.encode('${dialect.fullMarker(marker)}\n'));
    }

    final code = await exitFuture;
    await winch?.cancel();
    await sigint?.cancel();
    await stdoutSub.cancel();
    await stderrSub.cancel();
    await editor.close();
    if (context.detachRequested) {
      // `:detach` already printed the confirmation and resume hint, and the
      // remote shell keeps running — nothing more to report here. Still restore
      // the local terminal: a full-screen program may have left DEC private
      // modes on (mouse tracking, bracketed paste…) that would otherwise smear
      // stray escape sequences onto the terminal after we exit.
      stdout.write(_terminalModeReset);
      return 0;
    }
    if (session.wasDetached) {
      // Detached from another window (possibly mid full-screen program): restore
      // the local terminal so it is usable again, then point the user at how to
      // resume. The program owned the terminal and may have enabled DEC private
      // modes we must undo here — alt-screen, hidden cursor and SGR attributes,
      // but also mouse reporting and bracketed paste. Leaving mouse tracking on
      // makes every later mouse move spew SGR mouse reports (`ESC[<…M`) onto the
      // detached terminal; disable every mouse mode (1000/1002/1003 trackers and
      // the 1005/1006/1015 encodings) and bracketed paste (2004) too.
      stdout.write(_terminalModeReset);
      final shortId = session.detachOutcome?.shortId ?? '';
      stdout.writeln(_hrule());
      stdout.writeln(
        'Session detached (from another window) · ${descriptor.id.value}',
      );
      if (shortId.isNotEmpty) {
        stdout.writeln(
          'Resume with: omnyshell sessions resume '
          '${descriptor.id.value} $shortId',
        );
      }
      return 0;
    }
    // Close with a full-width rule so the finalized session output is clearly
    // separated from whatever the local terminal prints next.
    stdout.writeln(_hrule());
    stdout.writeln(
      'Session closed (exit $code) · ${descriptor.id.value} @ '
      '${client.config.hubUri}',
    );
    return code == -1 ? 0 : code;
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

/// The full width of the output terminal, or 80 when stdout is not a terminal.
int _terminalWidth() => stdout.hasTerminal ? stdout.terminalColumns : 80;

/// A dim, full-width horizontal rule sized to the current terminal.
String _hrule() {
  final line = '─' * _terminalWidth();
  if (!_colorEnabled()) return line;
  return '\u001b[2m$line\u001b[0m';
}

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
    ' ${paint(green, 'OmnyShell')} ${paint(dim, 'v$omnyShellVersion')} · '
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

/// An ephemeral, relative remote path used when `--mount-path` is omitted. The
/// node's drive service creates it (`Directory(root).create(recursive: true)`)
/// and the exec backend resolves a relative `cwd` against the same node working
/// directory, so the mount and the command share the same location.
String _ephemeralMountPath(String name) {
  final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_.-]+'), '-');
  final trimmed = slug.replaceAll(RegExp(r'^-+|-+$'), '');
  final base = trimmed.isEmpty ? 'run' : trimmed;
  final id = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return '.omnyshell/run/$base-${id.substring(id.length - 6)}';
}

/// Mounts [localDir] onto [nodeId], runs [command] inside it, and syncs the
/// node's modifications back to local. Shared by `exec --mount` and `run`.
///
/// The mount is always read-write so remote changes can be pulled back. With
/// `syncInterval > 0` the mount is also synced periodically while the command
/// runs; a final sync always runs on completion. The mount is left registered
/// unless [unmount] is set, in which case [cleanRemote] also deletes the node's
/// copy. Sets [exitCode] to the remote command's exit code.
Future<void> _execWithMount(
  ArgResults args, {
  required String nodeId,
  required String command,
  required String localDir,
}) async {
  final explicitCwd = args['cwd'] as String?;
  final mountName = args['mount-name'] as String?;
  final remotePath =
      (args['mount-path'] as String?) ??
      _ephemeralMountPath(mountName ?? _localDirName(localDir));
  final initialSync = args['initial-sync'] as bool;
  final syncInterval =
      int.tryParse((args['sync-interval'] as String?) ?? '0') ?? 0;
  final unmount = args['unmount'] as bool;
  final cleanRemote = args['clean-remote'] as bool;

  final client = await _connectClient(args);
  final bar = SyncProgressBar();
  try {
    final mgr = await DriveManager.open(client);
    final rec = await mgr.mountDirectory(
      localDir: localDir,
      nodeId: nodeId,
      remotePath: remotePath,
      name: mountName,
      readWrite: true,
      initialSync: initialSync,
      onProgress: bar.update,
    );
    bar.finish();
    final cwd = explicitCwd ?? rec.remotePath;

    // Periodic sync-back while the command runs (remote-only changes pull down).
    Timer? poll;
    if (syncInterval > 0) {
      var syncing = false;
      poll = Timer.periodic(Duration(seconds: syncInterval), (_) async {
        if (syncing) return;
        syncing = true;
        try {
          await mgr.sync(rec.id, onProgress: bar.update);
          bar.finish();
        } on Object catch (e) {
          bar.finish();
          stderr.writeln('periodic sync failed: $e');
        } finally {
          syncing = false;
        }
      });
    }

    final ExecResult result;
    try {
      result = await client.execute(nodeId: nodeId, command: command, cwd: cwd);
    } finally {
      poll?.cancel();
    }
    stdout.write(result.stdoutText);
    stderr.write(result.stderrText);

    // Final sync: pull whatever the command changed on the node.
    await mgr.sync(rec.id, onProgress: bar.update);
    bar.finish();

    if (unmount) {
      await mgr.unmount(rec.id, keepRemote: !cleanRemote);
    } else {
      stderr.writeln(
        'mount ${rec.id} kept (sync with "omnyshell drive sync ${rec.id}", '
        'tear down with "omnyshell drive unmount ${rec.id}").',
      );
    }
    exitCode = result.exitCode;
  } on DriveException catch (e) {
    bar.finish();
    throw _CliError(e.message);
  } finally {
    await client.close();
  }
}

String _localDirName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
  return parts.isEmpty ? 'run' : parts.last;
}

class ExecCommand extends Command<void> {
  ExecCommand() {
    _addConnectionOptions(argParser);
    _addExecMountOptions(argParser);
  }

  @override
  String get name => 'exec';

  @override
  String get description => 'Run a command on a node and print its output.';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell exec web-01 "uname -a"',
    'omnyshell exec web-01 "make build" --cwd /srv/app',
    'omnyshell exec web-01 "make build" --mount ./src --sync-interval 10',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.length < 2) {
      throw _CliError('usage: omnyshell exec <node> "<command>"');
    }
    final nodeId = args.rest.first;
    final command = args.rest.sublist(1).join(' ');

    final mount = args['mount'] as String?;
    if (mount != null && mount.isNotEmpty) {
      await _execWithMount(
        args,
        nodeId: nodeId,
        command: command,
        localDir: mount,
      );
      return;
    }

    final client = await _connectClient(args);
    try {
      final result = await client.execute(
        nodeId: nodeId,
        command: command,
        cwd: args['cwd'] as String?,
      );
      stdout.write(result.stdoutText);
      stderr.write(result.stderrText);
      exitCode = result.exitCode;
    } finally {
      await client.close();
    }
  }
}

// --- run ---------------------------------------------------------------------

class RunCommand extends Command<void> {
  RunCommand() {
    _addConnectionOptions(argParser);
    // `run` mounts a directory by definition, so it uses --dir instead of the
    // optional --mount that `exec` exposes.
    _addExecMountOptions(argParser, includeMount: false);
    argParser.addOption(
      'dir',
      help: 'Local directory to mount and run inside (default: current dir).',
      defaultsTo: '.',
    );
  }

  @override
  String get name => 'run';

  @override
  String get description =>
      'Run a command remotely against a local directory: mount, run, sync back.';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell run web-01 "make build"',
    'omnyshell run web-01 "pytest" --dir ./project --sync-interval 5',
    'omnyshell run web-01 "make" --unmount --clean-remote',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.length < 2) {
      throw _CliError('usage: omnyshell run <node> "<command>"');
    }
    final nodeId = args.rest.first;
    final command = args.rest.sublist(1).join(' ');
    await _execWithMount(
      args,
      nodeId: nodeId,
      command: command,
      localDir: (args['dir'] as String?) ?? '.',
    );
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
  String? get usageFooter => _usageExamples(['omnyshell nodes list']);

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

// --- sessions (detachable) ---------------------------------------------------

class SessionsCommand extends Command<void> {
  SessionsCommand() {
    addSubcommand(SessionsListCommand());
    addSubcommand(SessionsPeekCommand());
    addSubcommand(SessionsResumeCommand());
    addSubcommand(SessionsDetachCommand());
    addSubcommand(SessionsKillCommand());
  }

  @override
  String get name => 'sessions';

  @override
  String get description =>
      'List, resume, detach or kill your sessions on a node.';
}

class SessionsListCommand extends Command<void> {
  SessionsListCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'list';

  @override
  String get description =>
      'List your sessions (active and detached) on a node.';

  @override
  String? get usageFooter => _usageExamples(['omnyshell sessions list web-01']);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell sessions list <node>');
    }
    final nodeId = args.rest.first;
    final client = await _connectClient(args);
    try {
      final sessions = await client.listSessions(nodeId: nodeId);
      if (sessions.isEmpty) {
        stdout.writeln('No sessions on $nodeId.');
        return;
      }
      final now = DateTime.now();
      stdout.writeln(
        '${'ID'.padRight(10)} ${'STATUS'.padRight(11)} '
        '${'AGE'.padRight(8)} ${'EXPIRES'.padRight(8)} '
        '${'COMMAND'.padRight(20)} PATH',
      );
      for (final s in sessions) {
        // Attached rows have no detachedAt; show age since the session opened.
        final age = _compactDuration(
          now.difference(s.detachedAt ?? s.createdAt),
        );
        final expires = s.expiresAt == null
            ? 'never'
            : _compactDuration(s.expiresAt!.difference(now));
        // '-' means: at the prompt, or the node could not determine it.
        final command = _truncateEnd(s.currentCommand ?? '-', 20);
        final path = _truncateStart(s.currentCwd ?? '-', 40);
        stdout.writeln(
          '${s.shortId.padRight(10)} ${s.state.name.padRight(11)} '
          '${age.padRight(8)} ${expires.padRight(8)} '
          '${command.padRight(20)} $path',
        );
      }
    } finally {
      await client.close();
    }
  }
}

class SessionsPeekCommand extends Command<void> {
  SessionsPeekCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'peek';

  @override
  String get description =>
      "Show a session's current screen without attaching to it.";

  @override
  String? get usageFooter =>
      _usageExamples(['omnyshell sessions peek web-01 a1b2c3d4']);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.length < 2) {
      throw _CliError('usage: omnyshell sessions peek <node> <session-id>');
    }
    final nodeId = args.rest[0];
    final sessionRef = args.rest[1];
    final client = await _connectClient(args);
    try {
      final result = await client.peekSession(
        nodeId: nodeId,
        sessionRef: sessionRef,
      );
      if (!result.ok) {
        stderr.writeln(result.message);
        exitCode = 1;
        return;
      }
      // One-shot dump of the captured screen — the same bytes a resume paints.
      // For a full-screen program (e.g. vim/top) the snapshot carries the
      // alternate-screen sequences; the trailing SGR reset stops colours from
      // bleeding into the local prompt afterwards.
      stdout.add(result.screen);
      stdout.write('\x1b[0m\n');
    } finally {
      await client.close();
    }
  }
}

class SessionsResumeCommand extends Command<void> {
  SessionsResumeCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'resume';

  @override
  String get description => 'Resume one of your detached sessions.';

  @override
  String? get usageFooter =>
      _usageExamples(['omnyshell sessions resume web-01 a1b2c3d4']);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.length < 2) {
      throw _CliError('usage: omnyshell sessions resume <node> <session-id>');
    }
    final nodeId = args.rest[0];
    final sessionRef = args.rest[1];
    final client = await _connectClient(args);
    try {
      final nodes = await client.listNodes();
      final descriptor = nodes.firstWhere(
        (n) => n.id.value == nodeId,
        orElse: () => throw _CliError('node not found: $nodeId'),
      );
      final pty = stdout.hasTerminal
          ? PtySpec(
              term: Platform.environment['TERM'] ?? 'xterm-256color',
              cols: stdout.terminalColumns,
              rows: stdout.terminalLines,
            )
          : null;
      final RemoteSession session;
      try {
        session = await client.resumeSession(
          nodeId: nodeId,
          sessionId: sessionRef,
          pty: pty,
        );
      } on SessionRejectedException catch (e) {
        throw _CliError('cannot resume session: ${e.message}');
      }
      exitCode = await _runInteractiveSession(
        client: client,
        descriptor: descriptor,
        session: session,
        nodeId: nodeId,
        pty: pty,
        resumedInAltScreen: session.resumedInAltScreen,
      );
    } finally {
      await client.close();
    }
  }
}

class SessionsDetachCommand extends Command<void> {
  SessionsDetachCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'detach';

  @override
  String get description =>
      'Detach a running session from another window (keeps it alive).';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell sessions detach web-01',
    'omnyshell sessions detach web-01 a1b2c3d4 1h',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError(
        'usage: omnyshell sessions detach <node> [session-id] [timeout]',
      );
    }
    final nodeId = args.rest[0];
    // Positional [session-id] and [timeout] are both optional and order-tolerant:
    // a token parses as a timeout (e.g. 30m) or otherwise is treated as the id.
    String sessionRef = '';
    Duration? timeout;
    for (final tok in args.rest.skip(1)) {
      final asTimeout = _parseTimeoutArg(tok);
      if (asTimeout != null && timeout == null) {
        timeout = asTimeout;
      } else {
        sessionRef = tok;
      }
    }
    final client = await _connectClient(args);
    try {
      final res = await client.detachActiveSession(
        nodeId: nodeId,
        sessionRef: sessionRef,
        timeout: timeout,
      );
      if (!res.ok) {
        stdout.writeln(res.message);
        exitCode = 1;
        return;
      }
      stdout.writeln('Session detached successfully.');
      stdout.writeln('');
      stdout.writeln('Session ID: ${res.shortId}');
      stdout.writeln('');
      stdout.writeln('Resume later using:');
      stdout.writeln('');
      stdout.writeln('  omnyshell sessions resume $nodeId ${res.shortId}');
    } finally {
      await client.close();
    }
  }
}

class SessionsKillCommand extends Command<void> {
  SessionsKillCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'kill';

  @override
  String get description =>
      'Terminate one of your sessions (running or detached).';

  @override
  String? get usageFooter =>
      _usageExamples(['omnyshell sessions kill web-01 a1b2c3d4']);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.length < 2) {
      throw _CliError('usage: omnyshell sessions kill <node> <session-id>');
    }
    final nodeId = args.rest[0];
    final sessionRef = args.rest[1];
    final client = await _connectClient(args);
    try {
      final result = await client.killSession(
        nodeId: nodeId,
        sessionRef: sessionRef,
      );
      stdout.writeln(result.message);
      if (!result.ok) exitCode = 1;
    } finally {
      await client.close();
    }
  }
}

/// Parses a timeout argument like `30m`, `2h`, `1d`, `45s`; `null` if it is not
/// a well-formed duration (so it can instead be treated as a session id).
Duration? _parseTimeoutArg(String raw) {
  final m = RegExp(r'^(\d+)([smhd])$').firstMatch(raw.trim().toLowerCase());
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)!) {
    's' => Duration(seconds: n),
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    'd' => Duration(days: n),
    _ => null,
  };
}

/// Formats a (possibly negative) [d] compactly, e.g. `45s`, `10m`, `2h`, `3d`.
String _compactDuration(Duration d) {
  if (d.isNegative) return '0s';
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// Truncates [s] to [max] characters, marking elision with a trailing `…`.
String _truncateEnd(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1)}…';

/// Truncates [s] to [max] characters keeping the *tail* (most informative for a
/// path), marking elision with a leading `…`.
String _truncateStart(String s, int max) =>
    s.length <= max ? s : '…${s.substring(s.length - (max - 1))}';

// --- tunnel ------------------------------------------------------------------

class TunnelCommand extends Command<void> {
  TunnelCommand() {
    addSubcommand(TunnelOpenCommand());
    addSubcommand(TunnelListCommand());
    addSubcommand(TunnelCloseCommand());
  }

  @override
  String get name => 'tunnel';

  @override
  String get description =>
      'Expose an internal TCP port through a public Hub port.';
}

class TunnelOpenCommand extends Command<void> {
  TunnelOpenCommand() {
    _addConnectionOptions(argParser);
    argParser
      ..addOption(
        'public-port',
        abbr: 'p',
        help: 'Request a specific public port (must be within the hub range).',
      )
      ..addFlag(
        'local',
        negatable: false,
        help:
            "Expose this machine's port instead of a node's. The command then "
            'stays running to serve forwarded connections.',
      );
  }

  @override
  String get name => 'open';

  @override
  String get description =>
      "Expose a node's (or --local) TCP port on a public Hub port.";

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell tunnel open web-01 5432',
    'omnyshell tunnel open web-01 5432 --public-port 20010',
    'omnyshell tunnel open --local 3000',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    final local = args['local'] as bool;
    final rest = args.rest;
    final String nodeId;
    final String portStr;
    if (local) {
      if (rest.isEmpty) {
        throw _CliError('usage: omnyshell tunnel open --local <port>');
      }
      nodeId = '';
      portStr = rest.first;
    } else {
      if (rest.length < 2) {
        throw _CliError(
          'usage: omnyshell tunnel open <node> <port> [--public-port N]',
        );
      }
      nodeId = rest[0];
      portStr = rest[1];
    }
    final targetPort = int.tryParse(portStr);
    if (targetPort == null || targetPort < 1 || targetPort > 65535) {
      throw _CliError('invalid target port "$portStr" (1-65535)');
    }
    int? publicPort;
    final pp = args['public-port'] as String?;
    if (pp != null && pp.isNotEmpty) {
      publicPort = int.tryParse(pp);
      if (publicPort == null) throw _CliError('invalid --public-port "$pp"');
    }

    final client = await _connectClient(args);
    try {
      final t = await client.openTunnel(
        nodeId: nodeId,
        targetPort: targetPort,
        publicPort: publicPort,
        local: local,
      );
      final host = t.publicHost.isEmpty
          ? client.config.hubUri.host
          : t.publicHost;
      final target = local
          ? 'localhost:${t.targetPort}'
          : '$nodeId:$targetPort';
      stdout.writeln(
        'Tunnel ${t.shortId} open: $host:${t.publicPort} -> $target',
      );
      if (local) {
        stdout.writeln('Serving this machine. Press Ctrl-C to stop.');
        final done = Completer<void>();
        late StreamSubscription<ProcessSignal> sub;
        sub = ProcessSignal.sigint.watch().listen((_) async {
          stdout.writeln('\nClosing tunnel...');
          await sub.cancel();
          if (!done.isCompleted) done.complete();
        });
        await done.future;
        await client.closeTunnel(t.tunnelId);
      } else {
        stdout.writeln('Close with: omnyshell tunnel close ${t.shortId}');
      }
    } on TunnelRejectedException catch (e) {
      stderr.writeln('tunnel: ${e.message}');
      exitCode = 1;
    } finally {
      await client.close();
    }
  }
}

class TunnelListCommand extends Command<void> {
  TunnelListCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'list';

  @override
  List<String> get aliases => const ['ls'];

  @override
  String get description => 'List your active tunnels.';

  @override
  String? get usageFooter => _usageExamples(['omnyshell tunnel list']);

  @override
  Future<void> run() async {
    final client = await _connectClient(argResults!);
    try {
      final tunnels = await client.listTunnels();
      if (tunnels.isEmpty) {
        stdout.writeln('No tunnels.');
        return;
      }
      stdout.writeln(
        '${'ID'.padRight(10)} ${'PUBLIC'.padRight(24)} '
        '${'NODE'.padRight(16)} TARGET',
      );
      for (final t in tunnels) {
        final host = t.publicHost.isEmpty
            ? client.config.hubUri.host
            : t.publicHost;
        stdout.writeln(
          '${t.shortId.padRight(10)} '
          '${'$host:${t.publicPort}'.padRight(24)} '
          '${t.nodeId.padRight(16)} ${t.targetHost}:${t.targetPort}',
        );
      }
    } finally {
      await client.close();
    }
  }
}

class TunnelCloseCommand extends Command<void> {
  TunnelCloseCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'close';

  @override
  String get description => 'Close a tunnel by id or unambiguous prefix.';

  @override
  String? get usageFooter =>
      _usageExamples(['omnyshell tunnel close a1b2c3d4']);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell tunnel close <id>');
    }
    final client = await _connectClient(args);
    try {
      final result = await client.closeTunnel(args.rest.first);
      if (result.ok) {
        stdout.writeln('Tunnel closed.');
      } else {
        stderr.writeln('tunnel: ${result.message}');
        exitCode = 1;
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
  String? get usageFooter => _usageExamples(['omnyshell whoami']);

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

// --- drive -------------------------------------------------------------------

class DriveCommand extends Command<void> {
  DriveCommand() {
    addSubcommand(DriveMountCommand());
    addSubcommand(DriveListCommand());
    addSubcommand(DriveStatusCommand());
    addSubcommand(DriveSyncCommand());
    addSubcommand(DriveWatchCommand());
    addSubcommand(DriveResolveCommand());
    addSubcommand(DriveUnmountCommand());
    addSubcommand(DriveRemountCommand());
  }

  @override
  String get name => 'drive';

  @override
  String get description =>
      'Mount local directories or git repos onto remote node paths (OmnyDrive).';
}

/// Splits a `<node>:<remote-path>` target into its node id and path.
({String nodeId, String remotePath}) _parseTarget(String raw) {
  final i = raw.indexOf(':');
  if (i <= 0 || i == raw.length - 1) {
    throw _CliError('target must be "<node>:<remote-path>" (got "$raw")');
  }
  return (nodeId: raw.substring(0, i), remotePath: raw.substring(i + 1));
}

String _mountLine(MountRecord r) {
  final st = r.syncState;
  final src = r.isGit ? (r.gitUrl ?? 'git') : (r.localPath ?? '?');
  final mode = r.readWrite ? 'rw' : 'ro';
  return '${r.id.padRight(22)} ${st.status.wireValue.padRight(10)} '
      '$mode  $src -> ${r.nodeId}:${r.remotePath}';
}

class DriveMountCommand extends Command<void> {
  DriveMountCommand() {
    _addConnectionOptions(argParser);
    argParser
      ..addFlag(
        'rw',
        negatable: false,
        help: 'Writable node mirror (syncs back)',
      )
      ..addFlag(
        'initial-sync',
        defaultsTo: true,
        help: 'Populate the node path on mount',
      )
      ..addOption('name', help: 'Mount name (defaults to the source name)')
      ..addOption(
        'git',
        help: 'Mount a git repository URL instead of a local dir',
      )
      ..addOption('branch', help: 'Git branch to clone (git mounts)')
      ..addOption('depth', help: 'Git shallow clone depth (git mounts)');
  }

  @override
  String get name => 'mount';

  @override
  String get description =>
      'Mount a local directory (or --git URL) onto <node>:<remote-path>.';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell drive mount ./src web-01:/srv/app --rw',
    'omnyshell drive mount --git https://github.com/me/repo.git web-01:/srv/repo',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    final gitUrl = args['git'] as String?;
    final client = await _connectClient(args);
    final bar = SyncProgressBar();
    try {
      final mgr = await DriveManager.open(client);
      final MountRecord rec;
      if (gitUrl != null && gitUrl.isNotEmpty) {
        if (rest.isEmpty) {
          throw _CliError(
            'usage: omnyshell drive mount --git <url> <node>:<remote-path>',
          );
        }
        final t = _parseTarget(rest.first);
        rec = await mgr.mountGit(
          url: gitUrl,
          nodeId: t.nodeId,
          remotePath: t.remotePath,
          name: args['name'] as String?,
          branch: args['branch'] as String?,
          depth: int.tryParse((args['depth'] as String?) ?? ''),
          readWrite: args['rw'] as bool,
          onProgress: bar.update,
        );
      } else {
        if (rest.length < 2) {
          throw _CliError(
            'usage: omnyshell drive mount <local-dir> <node>:<remote-path>',
          );
        }
        final t = _parseTarget(rest[1]);
        rec = await mgr.mountDirectory(
          localDir: rest.first,
          nodeId: t.nodeId,
          remotePath: t.remotePath,
          name: args['name'] as String?,
          readWrite: args['rw'] as bool,
          initialSync: args['initial-sync'] as bool,
          onProgress: bar.update,
        );
      }
      bar.finish();
      stdout.writeln('Mounted ${rec.id}');
      stdout.writeln('  ${_mountLine(rec)}');
    } on DriveException catch (e) {
      throw _CliError(e.message);
    } finally {
      await client.close();
    }
  }
}

class DriveListCommand extends Command<void> {
  @override
  String get name => 'ls';

  @override
  List<String> get aliases => const ['list'];

  @override
  String get description => 'List active mounts and their sync state.';

  @override
  String? get usageFooter => _usageExamples(['omnyshell drive ls']);

  @override
  Future<void> run() async {
    final store = await MountStore.load();
    final mounts = store.mounts.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (mounts.isEmpty) {
      stdout.writeln('No mounts.');
      return;
    }
    for (final r in mounts) {
      stdout.writeln(_mountLine(r));
    }
  }
}

class DriveStatusCommand extends Command<void> {
  @override
  String get name => 'status';

  @override
  String get description => 'Show detailed sync state for a mount.';

  @override
  String? get usageFooter =>
      _usageExamples(['omnyshell drive status a1b2c3d4']);

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw _CliError('usage: omnyshell drive status <mount-id>');
    }
    final store = await MountStore.load();
    final r = store.mounts[rest.first];
    if (r == null) throw _CliError('no such mount: ${rest.first}');
    final st = r.syncState;
    stdout
      ..writeln('Mount:    ${r.id}')
      ..writeln(
        'Kind:     ${r.kind} (${r.readWrite ? 'read-write' : 'read-only'})',
      )
      ..writeln('Source:   ${r.isGit ? r.gitUrl : r.localPath}')
      ..writeln('Target:   ${r.nodeId}:${r.remotePath}')
      ..writeln('Status:   ${st.status.wireValue}')
      ..writeln('Baseline: ${st.baselineRef}')
      ..writeln('Synced:   ${st.lastSyncedAt?.toIso8601String() ?? 'never'}');
    if (st.lastError != null) stdout.writeln('Error:    ${st.lastError}');
  }
}

class DriveSyncCommand extends Command<void> {
  DriveSyncCommand() {
    _addConnectionOptions(argParser);
    argParser
      ..addFlag('push', negatable: false, help: 'Force push (local -> node)')
      ..addFlag('pull', negatable: false, help: 'Force pull (node -> local)');
  }

  @override
  String get name => 'sync';

  @override
  String get description => 'Synchronize a mount once (push/pull/auto).';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell drive sync a1b2c3d4',
    'omnyshell drive sync a1b2c3d4 --push',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell drive sync <mount-id>');
    }
    final push = args['push'] as bool;
    final pull = args['pull'] as bool;
    if (push && pull) throw _CliError('choose only one of --push / --pull');
    final direction = push
        ? SyncDirection.push
        : pull
        ? SyncDirection.pull
        : null;
    final client = await _connectClient(args);
    final bar = SyncProgressBar();
    try {
      final mgr = await DriveManager.open(client);
      final o = await mgr.sync(
        args.rest.first,
        direction: direction,
        onProgress: bar.update,
      );
      bar.finish();
      if (o.isConflict) {
        stdout.writeln('Conflict: ${o.conflict!.message}');
        exitCode = 1;
      } else if (o.direction == null) {
        stdout.writeln('Already up to date.');
      } else {
        final branch = o.publishedBranch == null
            ? ''
            : ' (published ${o.publishedBranch})';
        stdout.writeln(
          'Synced ${o.direction!.wireValue}: ${o.applied} change(s)$branch.',
        );
      }
    } on DriveException catch (e) {
      throw _CliError(e.message);
    } finally {
      await client.close();
    }
  }
}

class DriveWatchCommand extends Command<void> {
  DriveWatchCommand() {
    _addConnectionOptions(argParser);
    argParser
      ..addOption('interval', defaultsTo: '15', help: 'Poll interval (seconds)')
      ..addOption('debounce', defaultsTo: '500', help: 'FS debounce (ms)');
  }

  @override
  String get name => 'watch';

  @override
  String get description => 'Live auto-sync a mount until interrupted.';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell drive watch a1b2c3d4',
    'omnyshell drive watch a1b2c3d4 --interval 30',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell drive watch <mount-id>');
    }
    final client = await _connectClient(args);
    final mgr = await DriveManager.open(client);
    final bar = SyncProgressBar();
    ProcessSignal.sigint.watch().listen((_) async {
      stdout.writeln('\nStopped watching.');
      await client.close();
      exit(0);
    });
    try {
      await mgr.watch(
        args.rest.first,
        interval: Duration(seconds: int.parse(args['interval'] as String)),
        debounce: Duration(milliseconds: int.parse(args['debounce'] as String)),
        // Close off any live progress bar before printing a per-sync summary.
        log: (m) {
          bar.finish();
          stdout.writeln(m);
        },
        onProgress: bar.update,
      );
    } on DriveException catch (e) {
      await client.close();
      throw _CliError(e.message);
    }
  }
}

class DriveResolveCommand extends Command<void> {
  DriveResolveCommand() {
    _addConnectionOptions(argParser);
    argParser
      ..addFlag(
        'accept-local',
        negatable: false,
        help: 'Overwrite node with local',
      )
      ..addFlag(
        'accept-origin',
        negatable: false,
        help: 'Overwrite local with node',
      )
      ..addFlag('reclone', negatable: false, help: 'Re-fetch the node copy');
  }

  @override
  String get name => 'resolve';

  @override
  String get description => 'Resolve a conflicted mount.';

  @override
  String? get usageFooter => _usageExamples([
    'omnyshell drive resolve a1b2c3d4 --accept-local',
    'omnyshell drive resolve a1b2c3d4 --accept-origin',
  ]);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell drive resolve <mount-id> [--accept-*]');
    }
    final strategy = (args['accept-origin'] as bool)
        ? 'accept-origin'
        : (args['reclone'] as bool)
        ? 'reclone'
        : 'accept-local';
    final client = await _connectClient(args);
    final bar = SyncProgressBar();
    try {
      final mgr = await DriveManager.open(client);
      final o = await mgr.resolve(
        args.rest.first,
        strategy: strategy,
        onProgress: bar.update,
      );
      bar.finish();
      if (o.isConflict) {
        stdout.writeln('Still conflicted: ${o.conflict!.message}');
        exitCode = 1;
      } else {
        stdout.writeln('Resolved ($strategy): ${o.applied} change(s).');
      }
    } on DriveException catch (e) {
      throw _CliError(e.message);
    } finally {
      await client.close();
    }
  }
}

class DriveUnmountCommand extends Command<void> {
  DriveUnmountCommand() {
    _addConnectionOptions(argParser);
    argParser
      ..addFlag('sync-first', negatable: false, help: 'Run a final sync first')
      ..addFlag(
        'keep-remote',
        defaultsTo: true,
        help: 'Leave the node files in place (else delete them)',
      );
  }

  @override
  String get name => 'unmount';

  @override
  String get description => 'Tear down a mount.';

  @override
  String? get usageFooter =>
      _usageExamples(['omnyshell drive unmount a1b2c3d4']);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell drive unmount <mount-id>');
    }
    final id = args.rest.first;
    final syncFirst = args['sync-first'] as bool;
    final keepRemote = args['keep-remote'] as bool;

    // Only a final sync or remote cleanup needs the node; otherwise just drop
    // the local record.
    if (!syncFirst && keepRemote) {
      final store = await MountStore.load();
      if (store.mounts.remove(id) == null) {
        throw _CliError('no such mount: $id');
      }
      await store.save();
      stdout.writeln('Unmounted $id.');
      return;
    }
    final client = await _connectClient(args);
    try {
      final mgr = await DriveManager.open(client);
      await mgr.unmount(id, syncFirst: syncFirst, keepRemote: keepRemote);
      stdout.writeln('Unmounted $id.');
    } on DriveException catch (e) {
      throw _CliError(e.message);
    } finally {
      await client.close();
    }
  }
}

class DriveRemountCommand extends Command<void> {
  DriveRemountCommand() {
    _addConnectionOptions(argParser);
  }

  @override
  String get name => 'remount';

  @override
  String get description => 'Re-establish a mount after a node restart.';

  @override
  String? get usageFooter =>
      _usageExamples(['omnyshell drive remount a1b2c3d4']);

  @override
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell drive remount <mount-id>');
    }
    final client = await _connectClient(args);
    final bar = SyncProgressBar();
    try {
      final mgr = await DriveManager.open(client);
      final rec = await mgr.remount(args.rest.first, onProgress: bar.update);
      bar.finish();
      stdout.writeln('Remounted ${rec.id}.');
    } on DriveException catch (e) {
      throw _CliError(e.message);
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
      onBadCertificate: connection.onBadCertificate,
    ),
  );
  await client.connect();
  return client;
}
