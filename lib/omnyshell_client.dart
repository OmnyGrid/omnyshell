/// OmnyShell Client: authenticate with a Hub, discover nodes, and open exec or
/// interactive sessions.
///
/// ```dart
/// final client = ClientRuntime(ClientConfig(
///   hubUri: Uri.parse('wss://hub.example.com:8443'),
///   credentials: credentials,
/// ));
/// await client.connect();
/// final result = await client.execute(nodeId: 'web-01', command: 'uname -a');
/// ```
library;

import 'src/application/client/client_runtime.dart';

export 'omnyshell.dart';

export 'src/application/client/client_runtime.dart';
export 'src/application/client/local_command.dart';
export 'src/application/client/remote_session.dart';

/// Friendly alias for [ClientRuntime], the embeddable OmnyShell client.
typedef OmnyShellClient = ClientRuntime;
