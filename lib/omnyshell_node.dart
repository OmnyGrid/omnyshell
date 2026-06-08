/// OmnyShell Node: connect a machine to a Hub and serve secure sessions.
///
/// ```dart
/// final node = NodeRuntime(NodeConfig(
///   hubUri: Uri.parse('wss://hub.example.com:8443'),
///   nodeId: NodeId('web-01'),
///   credentials: credentials,
///   backend: ProcessShellBackend(),
/// ));
/// await node.connect();
/// ```
library;

import 'src/application/node/node_runtime.dart';

export 'omnyshell.dart';
export 'src/application/node/node_runtime.dart';
export 'src/application/node/reconnect_policy.dart';
export 'src/domain/backend/shell_backend.dart';
export 'src/infrastructure/backend/process_shell_backend.dart';
export 'src/infrastructure/backend/process_shell_session.dart';
export 'src/infrastructure/backend/pty/script_pty_shell_backend.dart';
export 'src/infrastructure/backend/pty/script_pty_shell_session.dart';

/// Friendly alias for [NodeRuntime], the embeddable OmnyShell node.
typedef OmnyShellNode = NodeRuntime;
