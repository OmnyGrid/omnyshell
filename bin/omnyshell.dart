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
      CommandRunner<void>('omnyshell', 'Secure, Hub-centric remote shell.')
        ..addCommand(LoginCommand())
        ..addCommand(LogoutCommand())
        ..addCommand(HubCommand())
        ..addCommand(NodeCommand())
        ..addCommand(ServiceCommand())
        ..addCommand(CertCommand())
        ..addCommand(ConnectCommand())
        ..addCommand(ExecCommand())
        ..addCommand(DriveCommand())
        ..addCommand(NodesCommand())
        ..addCommand(SessionsCommand())
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
) {
  if (args['insecure-skip-verify'] as bool? ?? false) {
    stderr.writeln(
      '[security] WARNING: --insecure-skip-verify is set — TLS certificate '
      'and hostname verification are DISABLED. Connection is vulnerable to '
      'MITM. Use only for trusted self-signed/dev hubs.',
    );
    return (_, _, _) => true;
  }
  return null;
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
  return (
    hubUri: hubUri,
    credentials: await session.toCredentialProvider(),
    security: _trustContextFromCa(ca),
    onBadCertificate: _insecureBadCertCallback(args),
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
    stderr.writeln('OmnyShell Hub v$omnyShellVersion starting...');
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
    _addNodeExtraOptions(argParser);
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
  Future<void> run() async {
    final args = argResults!;
    final role = _requireRole(args);
    final descriptor = _serviceDescriptor(role, args);
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
  Future<void> run() async {
    final args = argResults!;
    final role = _requireRole(args);
    final descriptor = _serviceDescriptor(role, args);
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

  Future<void> act(svc.DartServiceManager manager, String role);

  @override
  Future<void> run() async {
    final args = argResults!;
    final role = _requireRole(args);
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
          session.writeStdin(utf8.encode('${marker.command}\n'));
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
          final escaped = line.replaceAll("'", r"'\''");
          final tail = mayChangeCwdOrGit(line)
              ? marker.command
              : marker.pingCommand;
          final body = "eval '$escaped' ; $tail";
          // The remote shell runs with `stty -echo` so its prompt-free command
          // stream is never echoed. Re-enable echo just for the command so a
          // cooked-mode reader (read/cat/y-N) echoes the user's runtime input,
          // then disable it again before the marker. The `eval`+marker text
          // itself stays unechoed: those bytes arrive while echo is still off
          // (the shell only applies `stty echo` once it executes it). Password
          // prompts stay hidden because such programs disable echo themselves.
          // `2>/dev/null` keeps the pipe fallback (no tty) quiet.
          final cmd = interactive
              ? 'stty echo 2>/dev/null ; $body ; stty -echo 2>/dev/null'
              : body;
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

    // Keep the remote shell alive on Ctrl-C: a no-op INT trap means SIGINT
    // interrupts the foreground command (which inherits the default
    // disposition) without killing the non-interactive shell itself. Skipped
    // when resuming into a full-screen program: the shell already has the trap,
    // and writing the marker command would type it into the program.
    if (!resumedInAltScreen) {
      session.writeStdin(utf8.encode("trap ':' INT\n"));
      // Prime the first prompt: report the initial cwd.
      session.writeStdin(utf8.encode('${marker.command}\n'));
    }

    final code = await exitFuture;
    await winch?.cancel();
    await sigint?.cancel();
    await stdoutSub.cancel();
    await stderrSub.cancel();
    await editor.close();
    if (context.detachRequested) {
      // `:detach` already printed the confirmation and resume hint, and the
      // remote shell keeps running — nothing more to report here.
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
      stdout.write(
        '\x1b[?1049l\x1b[?25h\x1b[0m'
        '\x1b[?1000l\x1b[?1002l\x1b[?1003l'
        '\x1b[?1005l\x1b[?1006l\x1b[?1015l'
        '\x1b[?2004l',
      );
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

// --- sessions (detachable) ---------------------------------------------------

class SessionsCommand extends Command<void> {
  SessionsCommand() {
    addSubcommand(SessionsListCommand());
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
        '${'AGE'.padRight(8)} EXPIRES',
      );
      for (final s in sessions) {
        // Attached rows have no detachedAt; show age since the session opened.
        final age = _compactDuration(
          now.difference(s.detachedAt ?? s.createdAt),
        );
        final expires = s.expiresAt == null
            ? 'never'
            : _compactDuration(s.expiresAt!.difference(now));
        stdout.writeln(
          '${s.shortId.padRight(10)} ${s.state.name.padRight(11)} '
          '${age.padRight(8)} $expires',
        );
      }
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
  Future<void> run() async {
    final args = argResults!;
    final rest = args.rest;
    final gitUrl = args['git'] as String?;
    final client = await _connectClient(args);
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
        );
      }
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
    try {
      final mgr = await DriveManager.open(client);
      final o = await mgr.sync(args.rest.first, direction: direction);
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
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell drive watch <mount-id>');
    }
    final client = await _connectClient(args);
    final mgr = await DriveManager.open(client);
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
        log: stdout.writeln,
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
    try {
      final mgr = await DriveManager.open(client);
      final o = await mgr.resolve(args.rest.first, strategy: strategy);
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
  Future<void> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      throw _CliError('usage: omnyshell drive remount <mount-id>');
    }
    final client = await _connectClient(args);
    try {
      final mgr = await DriveManager.open(client);
      final rec = await mgr.remount(args.rest.first);
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
