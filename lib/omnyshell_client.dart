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
export 'src/application/client/remote_completion.dart'
    show remoteCompletionCommand;
export 'src/application/client/remote_session.dart';
export 'src/application/client/screen_mode_detector.dart';
export 'src/application/transfer/transfer_engine.dart'
    show
        TransferResult,
        TransferProgress,
        TransferPreflight,
        TransferException,
        ManifestEntry,
        kDefaultGzipLevel;

/// Friendly alias for [ClientRuntime], the embeddable OmnyShell client.
typedef OmnyShellClient = ClientRuntime;
