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
// Transport seam: the platform-default factory is used when
// `ClientConfig.connectionFactory` is null; native embedders that need TLS
// trust overrides (self-signed certs, pinning) pass `ioConnectionFactory(...)`.
export 'src/infrastructure/transport/connection_factory.dart'
    show ConnectionFactory;
export 'src/infrastructure/transport/io_connection_factory.dart'
    show ioConnectionFactory;
export 'src/application/client/command_classifier.dart'
    show launchesForegroundProgram, mayChangeCwdOrGit;
export 'src/application/client/download_archive.dart'
    show
        ArchiveFormat,
        parseArchiveFlag,
        archiveExtension,
        archiveError,
        remoteArchiveCommand;
export 'src/application/client/cwd_marker.dart';
export 'src/application/client/file_transfer.dart'
    show downloadPath, uploadPath, ClientTransferLink;
export 'src/application/client/line_editor.dart'
    show CommandHistory, LineEditor;
export 'src/application/client/drive/channel_content_source.dart';
export 'src/application/client/drive/drive_manager.dart';
export 'src/application/client/drive/drive_rpc_client.dart'
    show DriveRpcClient, DriveRpcException;
export 'src/application/client/drive/mount_store.dart';
export 'src/application/client/local_command.dart';
export 'src/application/client/file_transfer_commands.dart'
    show FileTransferCommands;
export 'src/application/client/ai_command.dart' show AiCommand;
export 'src/application/client/ai_commands_native.dart' show AiCommands;
export 'src/application/ai/agent_abort.dart';
export 'src/application/ai/agent_mode.dart';
export 'src/application/ai/agent_service.dart';
export 'src/application/ai/agent_style.dart';
export 'src/application/ai/ai_config.dart';
export 'src/application/ai/ai_config_io.dart'
    show AiConfigIo, AiConfigDescription;
export 'src/application/ai/command_runner.dart';
export 'src/application/ai/ai_validator.dart';
export 'src/application/ai/providers/ai_provider.dart';
export 'src/application/ai/providers/provider_factory.dart' show providerFor;
export 'src/application/client/interactive_shell_controller.dart';
export 'src/application/client/remote_completion.dart'
    show remoteCompletionCommand;
export 'src/application/client/remote_session.dart';
export 'src/application/client/shell_session_port.dart';
export 'src/application/client/screen_mode_detector.dart';
export 'src/application/client/shell_dialect.dart';
export 'src/application/transfer/transfer_engine.dart'
    show
        TransferResult,
        TransferProgress,
        TransferPreflight,
        TransferException,
        ManifestEntry,
        kDefaultGzipLevel;
export 'src/shared/utils/progress_bar.dart'
    show
        ProgressBar,
        SyncProgressBar,
        formatSyncProgress,
        formatSyncReport,
        formatFileDiff,
        formatDriveChanges;

/// Friendly alias for [ClientRuntime], the embeddable OmnyShell client.
typedef OmnyShellClient = ClientRuntime;
