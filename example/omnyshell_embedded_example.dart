/// Mixed-mode demo: a Hub, a Node and a Client embedded in one process, wired
/// over a real `wss` (WebSocket-on-TLS) loopback connection.
///
/// Provide a server certificate and key (PEM) via environment variables:
///
/// ```sh
/// # A throwaway self-signed cert for localhost (see test/support/certs):
/// openssl req -x509 -newkey rsa:2048 -nodes \
///   -keyout key.pem -out cert.pem -days 365 \
///   -subj "/CN=localhost" \
///   -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
///   -addext "basicConstraints=critical,CA:TRUE"
///
/// OMNYSHELL_CERT=cert.pem OMNYSHELL_KEY=key.pem \
///   dart run example/omnyshell_embedded_example.dart
/// ```
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_hub.dart';
import 'package:omnyshell/omnyshell_node.dart';

Future<void> main() async {
  final certPath = Platform.environment['OMNYSHELL_CERT'];
  final keyPath = Platform.environment['OMNYSHELL_KEY'];
  if (certPath == null || keyPath == null) {
    stderr.writeln('Set OMNYSHELL_CERT and OMNYSHELL_KEY to PEM file paths.');
    exitCode = 64;
    return;
  }

  // 1. Start a Hub with a token-based authenticator. The node logs in as the
  //    `node` account; the user `alice` is an admin.
  final hub = OmnyShellHub(
    HubConfig(
      host: '127.0.0.1',
      port: 0, // ephemeral
      securityContext: SecurityContext()
        ..useCertificateChain(certPath)
        ..usePrivateKey(keyPath),
      authenticator: TokenAuthenticator({
        'node-token': TokenGrant(
          principal: PrincipalId('node-account'),
          roles: {'node'},
        ),
        'alice-token': TokenGrant(
          principal: PrincipalId('alice'),
          displayName: 'Alice',
          roles: {'admin'},
        ),
      }),
    ),
  );
  await hub.start();
  final hubUri = Uri.parse('wss://127.0.0.1:${hub.port}');
  stdout.writeln('Hub listening on $hubUri');

  // A context trusting our self-signed cert (omit in production with a real CA).
  final trust = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificates(certPath);

  // 2. Connect a Node that serves shell sessions on this machine.
  final node = NodeRuntime(
    NodeConfig(
      hubUri: hubUri,
      nodeId: NodeId('local-01'),
      labels: const {'env': 'demo'},
      credentials: const TokenCredentialProvider(
        principal: 'node-account',
        token: 'node-token',
      ),
      backend: ProcessShellBackend(),
      securityContext: trust,
    ),
  );
  await node.connect();
  stdout.writeln('Node "local-01" registered.');

  // 3. Connect a Client and run a command end-to-end: Client → Hub → Node.
  final client = OmnyShellClient(
    ClientConfig(
      hubUri: hubUri,
      credentials: const TokenCredentialProvider(
        principal: 'alice',
        token: 'alice-token',
      ),
      connectionFactory: ioConnectionFactory(securityContext: trust),
    ),
  );
  await client.connect();
  stdout.writeln('Client authenticated as ${client.principal!.id.value}.');

  final nodes = await client.listNodes();
  stdout.writeln(
    'Discovered nodes: ${nodes.map((n) => n.id.value).join(', ')}',
  );

  final result = await client.execute(
    nodeId: 'local-01',
    command: 'echo "hello from \$(hostname)"',
  );
  stdout.writeln('exit=${result.exitCode}');
  stdout.write(result.stdoutText);

  // 4. Tidy up.
  await client.close();
  await node.shutdown();
  await hub.stop();
}
