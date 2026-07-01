import '../../../domain/auth/principal.dart';
import '../../../domain/entities/detached_session_info.dart';
import '../../../domain/entities/node_descriptor.dart';
import '../../../domain/entities/tunnel_info.dart';
import '../../ai/agent_mode.dart';
import '../../ai/ai_config.dart';
import '../../ai/ai_config_io.dart';
import '../../ai/ai_validator.dart';
import '../drive/drive_manager.dart';
import '../drive/mount_store.dart';

/// How a login authenticates to a Hub.
enum LoginMethod {
  /// A bearer token.
  token,

  /// An Ed25519 seed file at a path.
  publicKey,
}

/// A login already saved in the local credential store, shown so the dashboard
/// can reconnect with one keystroke instead of retyping credentials.
class SavedLogin {
  const SavedLogin({
    required this.hubUrl,
    required this.principal,
    required this.method,
    this.insecure = false,
    this.isDefault = false,
  });

  /// The Hub URL this login authenticates to (the credential-store key).
  final String hubUrl;

  /// The principal (login name).
  final String principal;

  /// The stored auth method (`token` or `publicKey`).
  final String method;

  /// Whether the login skips TLS verification.
  final bool insecure;

  /// Whether this is the remembered default Hub.
  final bool isDefault;
}

/// The persisted auth state the login screen renders: the remembered default
/// Hub and the list of saved logins.
class AuthSnapshot {
  const AuthSnapshot({this.defaultHub, this.logins = const []});

  /// The Hub URL used by default, or `null` when none is remembered.
  final String? defaultHub;

  /// Every saved login, newest-first is not guaranteed; render in list order.
  final List<SavedLogin> logins;
}

/// A request to authenticate and persist a new login, built from the login form.
class LoginRequest {
  const LoginRequest({
    required this.hub,
    required this.principal,
    required this.method,
    this.secret = '',
    this.ca,
    this.insecure = false,
  });

  /// The Hub URL (`wss://host:port`).
  final String hub;

  /// The principal (login name).
  final String principal;

  /// Whether [secret] is a token or a path to an Ed25519 seed file.
  final LoginMethod method;

  /// The bearer token (token method) or seed-file path (publicKey method).
  final String secret;

  /// Optional CA/cert PEM path to trust, remembered with the session.
  final String? ca;

  /// Whether to skip TLS certificate/hostname verification.
  final bool insecure;
}

/// The direction of a one-shot drive sync requested from the dashboard, mapped
/// by the backend onto OmnyDrive's `SyncDirection` (so the port stays free of
/// the `package:omnydrive` dependency).
enum DriveSyncDirection {
  /// Reconcile both sides automatically (the default).
  auto,

  /// Force push (local -> node).
  push,

  /// Force pull (node -> local).
  pull,
}

/// The outcome of a fire-and-forget session action (detach / terminate) that the
/// dashboard shows in its message bar.
class DashboardActionResult {
  const DashboardActionResult({required this.ok, required this.message});

  /// Whether the action succeeded.
  final bool ok;

  /// A short human-readable result to display.
  final String message;
}

/// The capability port the [DashboardApp](dashboard_app.dart) drives.
///
/// It hides all `dart:io`, networking and credential-storage details behind a
/// small, testable surface: the CLI provides a real implementation over
/// [ClientRuntime] + `CredentialStore`; tests provide a scripted fake.
///
/// Two operations — [resumeSession] and [peekSession] — take over the real
/// terminal (raw stdin/stdout) to run a live interactive session or paint a
/// captured screen. The app releases the terminal (leaves the alt-screen and
/// stops rendering) around those calls, so the implementation may use the real
/// terminal directly and surface its own errors there.
abstract interface class DashboardBackend {
  /// Reads the persisted auth state (default Hub + saved logins).
  Future<AuthSnapshot> authSnapshot();

  /// Connects to [hubUrl] using the saved session for it, making it the active
  /// connection. Returns the authenticated principal, or throws on failure.
  Future<Principal?> connect(String hubUrl);

  /// Validates [req] with a real handshake, persists it as the default login,
  /// and makes it the active connection. Returns the principal, or throws.
  Future<Principal?> login(LoginRequest req);

  /// Removes the saved login for [hubUrl]. If it is the active connection, the
  /// connection is closed.
  Future<void> logout(String hubUrl);

  /// The Hub URL of the active connection, or `null` when not connected.
  String? get connectedHub;

  /// Whether the active connection is currently live (authenticated + open).
  bool get isConnected;

  /// The authenticated principal of the active connection, or `null`.
  Principal? get principal;

  /// Lists nodes visible to the active connection.
  Future<List<NodeDescriptor>> listNodes();

  /// Lists the caller's sessions (active + detached) on [nodeId].
  Future<List<DetachedSessionInfo>> listSessions(String nodeId);

  /// Opens a new interactive shell on [nodeId], taking over the terminal until
  /// the session detaches or exits.
  Future<void> newSession(String nodeId);

  /// Detaches an active session (leaving it alive) named by [sessionRef].
  Future<DashboardActionResult> detachSession(
    String nodeId,
    String sessionRef, {
    Duration? timeout,
  });

  /// Terminates a session (running or detached) named by [sessionRef].
  Future<DashboardActionResult> killSession(String nodeId, String sessionRef);

  /// Resumes [sessionRef] on [nodeId] as a live interactive session, taking over
  /// the terminal until the session detaches or exits.
  Future<void> resumeSession(String nodeId, String sessionRef);

  /// Paints [sessionRef]'s captured screen to the terminal without attaching,
  /// then waits for a keypress before returning.
  Future<void> peekSession(String nodeId, String sessionRef);

  // ---- Tunnels (mirrors `omnyshell tunnel`) --------------------------------

  /// Lists the caller's active tunnels held by the Hub.
  Future<List<TunnelInfo>> listTunnels();

  /// Opens a tunnel exposing [nodeId]'s [targetPort] (or, when [local], this
  /// machine's port) on a public Hub port. A local tunnel keeps serving in the
  /// background over the dashboard's live connection — no terminal takeover.
  Future<DashboardActionResult> openTunnel({
    required String nodeId,
    required int targetPort,
    int? publicPort,
    bool local = false,
    bool secure = false,
  });

  /// Closes the caller's tunnel named by [tunnelRef] (id or unambiguous prefix).
  Future<DashboardActionResult> closeTunnel(String tunnelRef);

  // ---- Drive (mirrors `omnyshell drive`) -----------------------------------

  /// Lists active mounts and their sync state.
  Future<List<MountRecord>> listMounts();

  /// Mounts local directory [localDir] onto [target] (`<node>:<remote-path>`).
  Future<MountRecord> mountDirectory({
    required String localDir,
    required String target,
    String? name,
    bool rw = false,
    bool initialSync = true,
    List<String> include = const [],
    List<String> exclude = const [],
  });

  /// Mounts git repository [url] onto [target] (`<node>:<remote-path>`).
  Future<MountRecord> mountGit({
    required String url,
    required String target,
    String? name,
    String? branch,
    int? depth,
    bool rw = false,
  });

  /// Synchronizes the mount [mountId] once in [direction].
  Future<SyncOutcome> syncMount(
    String mountId, {
    DriveSyncDirection direction = DriveSyncDirection.auto,
  });

  /// Lists the files that differ between local and node for [mountId].
  Future<DriveChanges> mountConflicts(
    String mountId, {
    bool includeDiffs = false,
  });

  /// Shows how [path] differs between local and node for [mountId].
  Future<FileDiff> diffFile(String mountId, String path);

  /// Resolves a conflicted mount [mountId] with [strategy]
  /// (`accept-local` / `accept-origin` / `reclone`).
  Future<SyncOutcome> resolveMount(String mountId, {required String strategy});

  /// Resolves a single conflicted [path] in [mountId] with [strategy]
  /// (`accept-local` / `accept-origin`).
  Future<FileResolveOutcome> resolveFile(
    String mountId,
    String path, {
    required String strategy,
  });

  /// Re-establishes the mount [mountId] after a node restart.
  Future<MountRecord> remount(String mountId);

  /// Tears down the mount [mountId].
  Future<DashboardActionResult> unmount(
    String mountId, {
    bool syncFirst = false,
    bool keepRemote = true,
  });

  /// Live auto-syncs the mount [mountId] until interrupted (Ctrl-C). Takes over
  /// the terminal — the app calls this with the terminal released.
  Future<void> watchMount(String mountId);

  // ---- AI (mirrors `omnyshell ai`) -----------------------------------------

  /// Reads the resolved AI configuration (key masked / status only).
  Future<AiConfigDescription> aiDescribe();

  /// Writes AI settings to `~/.omnyshell/ai.yaml`. A non-null empty string
  /// clears that field back to its default; `null` leaves it untouched.
  Future<void> aiConfig({
    AiProviderKind? provider,
    String? model,
    String? plannerModel,
    String? executorModel,
    String? explainerModel,
    String? apiKey,
    AgentMode? mode,
    String? language,
    String? baseUrl,
    int? maxSteps,
  });

  /// Validates the configured key and models with live provider requests.
  Future<List<AiModelCheck>> aiTest();

  /// Closes the active connection and releases resources.
  Future<void> close();
}
