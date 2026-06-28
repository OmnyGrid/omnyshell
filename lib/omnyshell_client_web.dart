/// OmnyShell Client for the **browser** (dart2js / DDC): authenticate with a
/// Hub, discover nodes, and manage sessions — over the platform WebSocket.
///
/// This is the browser-safe counterpart of `omnyshell_client.dart`. The latter
/// re-exports `dart:io`-bound helpers (progress bars, local commands, file
/// transfer, OmnyDrive) that cannot compile to JavaScript; this barrel exports
/// only the subset that runs in a browser. Import **this**, never
/// `omnyshell_client.dart`, from web code.
///
/// ```dart
/// final client = ClientRuntime(ClientConfig(
///   hubUri: Uri.parse('wss://hub.example.com:8443'),
///   credentials: TokenCredentialProvider(principal: 'alice', token: '...'),
/// ));
/// await client.connect();
/// final nodes = await client.listNodes();
/// ```
library;

import 'src/application/client/client_runtime.dart';

// Client runtime + session handle (the embeddable API surface).
export 'src/application/client/client_runtime.dart';
export 'src/application/client/remote_session.dart';

// Embeddable interactive-shell controller (drives a RemoteSession as an
// interactive shell: prompt priming, marker-based completion, passthrough) +
// the narrow session port it runs on.
export 'src/application/client/interactive_shell_controller.dart';
export 'src/application/client/shell_session_port.dart';

// Interactive shell integration (pure Dart, browser-safe): cwd/prompt markers,
// per-shell command dialects, and command classification. A web client driving
// a pipe-mode shell reuses these exactly as the CLI does (prompt, echo, marker
// completion), so its wire behaviour matches the CLI byte-for-byte.
export 'src/application/client/command_classifier.dart'
    show launchesForegroundProgram, mayChangeCwdOrGit;
export 'src/application/client/cwd_marker.dart';
export 'src/application/client/shell_dialect.dart';

// Browser-safe local `:` commands (help, info, tree, tunnel, …) and the
// registry that dispatches them. File-transfer commands (:download/:upload/
// :drive) need dart:io and are intentionally excluded; a web client installs
// the rest with `LocalCommandRegistry.withDefaults()`.
export 'src/application/client/local_command.dart';

// Credentials (token + Ed25519; both pure crypto, browser-safe).
export 'src/infrastructure/auth/credential_provider.dart';

// Transport seam — lets web code inject fakes / a custom connection.
export 'src/infrastructure/transport/connection_factory.dart';
export 'src/infrastructure/transport/ws_channel_connection.dart';

// Identity (auth principal).
export 'src/domain/auth/principal.dart';

// Domain entities surfaced by the client API.
export 'src/domain/entities/detached_session_info.dart';
export 'src/domain/entities/node_capabilities.dart';
export 'src/domain/entities/node_descriptor.dart';
export 'src/domain/entities/platform_info.dart';
export 'src/domain/entities/session.dart';
export 'src/domain/entities/tunnel_info.dart';

// Session/PTY value objects.
export 'src/domain/backend/pty_spec.dart';
export 'src/domain/backend/shell_family.dart';

// Value objects.
export 'src/domain/value_objects/channel_id.dart';
export 'src/domain/value_objects/node_id.dart';
export 'src/domain/value_objects/omny_uid.dart';
export 'src/domain/value_objects/principal_id.dart';
export 'src/domain/value_objects/public_key.dart';
export 'src/domain/value_objects/session_id.dart';

// Errors.
export 'src/shared/errors/error_codes.dart';
export 'src/shared/errors/omnyshell_exception.dart';

// Clock (test injection).
export 'src/shared/utils/clock.dart';

// Protocol (for building test doubles / a fake hub connection).
export 'src/protocol/channel.dart';
export 'src/protocol/channel_multiplexer.dart';
export 'src/protocol/control_message.dart';
export 'src/protocol/data_opcode.dart';
export 'src/protocol/frame_codec.dart';
export 'src/protocol/omnyshell_connection.dart';
export 'src/protocol/omnyshell_frame.dart';
export 'src/protocol/protocol_version.dart';

/// Friendly alias for [ClientRuntime], the embeddable OmnyShell client.
typedef OmnyShellClient = ClientRuntime;
