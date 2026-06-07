/// OmnyShell core: the shared protocol, domain model and contracts used by the
/// Hub, Node and Client libraries.
///
/// Most applications import one of the role-specific libraries instead:
/// `omnyshell_hub.dart`, `omnyshell_node.dart` or `omnyshell_client.dart`.
library;

// Shared utilities & errors.
export 'src/shared/errors/error_codes.dart';
export 'src/shared/errors/omnyshell_exception.dart';
export 'src/shared/utils/clock.dart';
export 'src/shared/utils/id_generator.dart';

// Domain value objects.
export 'src/domain/value_objects/channel_id.dart';
export 'src/domain/value_objects/node_id.dart';
export 'src/domain/value_objects/principal_id.dart';
export 'src/domain/value_objects/public_key.dart';
export 'src/domain/value_objects/session_id.dart';

// Domain entities.
export 'src/domain/entities/node_capabilities.dart';
export 'src/domain/entities/node_descriptor.dart';
export 'src/domain/entities/platform_info.dart';
export 'src/domain/entities/session.dart';

// Auth & backend contracts.
export 'src/domain/auth/authenticator.dart';
export 'src/domain/auth/authorizer.dart';
export 'src/domain/auth/credential.dart';
export 'src/domain/auth/principal.dart';
export 'src/domain/backend/pty_spec.dart';
export 'src/domain/backend/shell_backend.dart';
export 'src/domain/backend/shell_request.dart';
export 'src/domain/backend/shell_session.dart';

// Credential providers (shared by client and node).
export 'src/infrastructure/auth/credential_provider.dart';

// Protocol.
export 'src/protocol/channel.dart';
export 'src/protocol/channel_multiplexer.dart';
export 'src/protocol/control_message.dart';
export 'src/protocol/data_opcode.dart';
export 'src/protocol/frame_codec.dart';
export 'src/protocol/omnyshell_connection.dart';
export 'src/protocol/omnyshell_frame.dart';
export 'src/protocol/protocol_version.dart';
