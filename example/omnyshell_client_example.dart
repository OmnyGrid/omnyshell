/// Client SDK demo: connect to a running Hub, discover nodes, run a command and
/// open an interactive session.
///
/// ```sh
/// OMNYSHELL_HUB=wss://hub.example.com:8443 \
/// OMNYSHELL_PRINCIPAL=alice \
/// OMNYSHELL_TOKEN=... \
///   dart run example/omnyshell_client_example.dart worker-prod-01
/// ```
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final hub = env['OMNYSHELL_HUB'] ?? 'wss://127.0.0.1:8443';
  final principal = env['OMNYSHELL_PRINCIPAL'];
  final token = env['OMNYSHELL_TOKEN'];
  if (principal == null || token == null) {
    stderr.writeln('Set OMNYSHELL_PRINCIPAL and OMNYSHELL_TOKEN.');
    exitCode = 64;
    return;
  }
  final nodeId = args.isNotEmpty ? args.first : 'worker-prod-01';

  final client = OmnyShellClient(
    ClientConfig(
      hubUri: Uri.parse(hub),
      credentials: TokenCredentialProvider(principal: principal, token: token),
    ),
  );

  try {
    await client.connect();
    stdout.writeln('Authenticated as ${client.principal!.id.value}.');

    // Discover nodes.
    final nodes = await client.listNodes();
    for (final node in nodes) {
      stdout.writeln(
        '  ${node.id.value} — ${node.platform.os}/${node.platform.arch} '
        '(${node.online ? 'online' : 'offline'})',
      );
    }

    // One-shot command execution.
    final result = await client.execute(nodeId: nodeId, command: 'uname -a');
    stdout.writeln('\n\$ uname -a  (exit ${result.exitCode})');
    stdout.write(result.stdoutText);
  } on AuthException catch (e) {
    stderr.writeln('Authentication failed: ${e.message}');
    exitCode = 1;
  } on SessionRejectedException catch (e) {
    stderr.writeln('Session rejected: ${e.message}');
    exitCode = 1;
  } finally {
    await client.close();
  }
}
