import 'dart:async';

import 'package:omnydrive/omnydrive.dart' show SyncRef, SyncState, SyncStatus;
import 'package:omnyshell/src/application/ai/agent_mode.dart';
import 'package:omnyshell/src/application/ai/ai_config.dart'
    show AiProviderKind;
import 'package:omnyshell/src/application/ai/ai_config_io.dart'
    show AiConfigDescription;
import 'package:omnyshell/src/application/ai/ai_validator.dart'
    show AiModelCheck;
import 'package:omnyshell/src/application/client/dashboard/dashboard_app.dart';
import 'package:omnyshell/src/application/client/dashboard/dashboard_backend.dart';
import 'package:omnyshell/src/application/client/drive/drive_manager.dart'
    show SyncOutcome, DriveChanges, FileDiff, FileResolveOutcome;
import 'package:omnyshell/src/application/client/drive/mount_store.dart'
    show MountRecord;
import 'package:omnyshell/src/application/client/ide/tui/screen_buffer.dart';
import 'package:omnyshell/src/application/client/ide/tui/style.dart';
import 'package:omnyshell/src/application/client/ide/tui/key_decoder.dart';
import 'package:omnyshell/src/application/client/ide/tui/terminal_driver.dart';
import 'package:omnyshell/src/protocol/control_message.dart'
    show DriveCredentialEntry;
import 'package:omnyshell/src/domain/auth/principal.dart';
import 'package:omnyshell/src/domain/entities/detached_session_info.dart';
import 'package:omnyshell/src/domain/entities/hub_info.dart';
import 'package:omnyshell/src/domain/entities/node_capabilities.dart';
import 'package:omnyshell/src/domain/entities/node_descriptor.dart';
import 'package:omnyshell/src/domain/entities/platform_info.dart';
import 'package:omnyshell/src/domain/entities/session.dart';
import 'package:omnyshell/src/domain/entities/tunnel_info.dart';
import 'package:omnyshell/src/domain/value_objects/node_id.dart';
import 'package:omnyshell/src/domain/value_objects/principal_id.dart';
import 'package:omnyshell/src/shared/errors/omnyshell_exception.dart';
import 'package:omnyshell/src/version.dart';
import 'package:test/test.dart';

/// A scriptable [TerminalDriver] backed by a broadcast input stream (so the app
/// can cancel and re-listen around a resume/peek handoff, exactly as the real
/// [Terminal] does with the shared stdin broadcast).
class FakeTerminal implements TerminalDriver {
  FakeTerminal({this.cols = 100, this.rows = 30});
  final int cols;
  final int rows;
  final _input = StreamController<List<int>>.broadcast();
  ScreenBuffer? lastFrame;
  bool entered = false;

  void send(List<int> bytes) => _input.add(bytes);

  @override
  ({int cols, int rows}) get size => (cols: cols, rows: rows);
  @override
  void enter() => entered = true;
  @override
  void leave() => entered = false;
  @override
  void invalidate() {}
  @override
  void present(ScreenBuffer frame, {int? cursorX, int? cursorY}) =>
      lastFrame = frame;
  @override
  Stream<List<int>> get input => _input.stream;
  @override
  Stream<void> get resizeEvents => const Stream<void>.empty();
}

/// A fake [DashboardBackend] that returns scripted nodes/sessions and records
/// every call so tests can assert what the app invoked.
class FakeDashboardBackend implements DashboardBackend {
  FakeDashboardBackend({
    this.auth = const AuthSnapshot(),
    this.nodes = const [],
    this.sessions = const [],
  });

  AuthSnapshot auth;
  List<NodeDescriptor> nodes;
  List<DetachedSessionInfo> sessions;
  final List<String> calls = [];

  // Scripted tunnel / drive / AI state.
  List<TunnelInfo> tunnels = const [];
  List<MountRecord> mounts = const [];
  DriveChanges changes = DriveChanges();
  AiConfigDescription? aiDescription;
  List<AiModelCheck> aiChecks = const [];

  /// When set, the next list call throws (to exercise refresh soft-fail /
  /// dropped-connection handling).
  bool failNodes = false;
  bool failSessions = false;

  String? _hub;
  Principal? _principal;

  /// When false, simulates a dropped Hub connection so list/action failures
  /// route back to the login screen.
  bool connected = true;

  @override
  String? get connectedHub => _hub;
  @override
  bool get isConnected => _hub != null && connected;
  @override
  Principal? get principal => _principal;

  @override
  Future<AuthSnapshot> authSnapshot() async => auth;

  @override
  Future<Principal?> connect(String hubUrl) async {
    calls.add('connect:$hubUrl');
    _hub = hubUrl;
    _principal = Principal(id: PrincipalId('alice'), displayName: 'alice');
    return _principal;
  }

  @override
  Future<Principal?> login(LoginRequest req) async {
    calls.add('login:${req.hub}:${req.principal}:${req.method.name}');
    _hub = req.hub;
    _principal = Principal(
      id: PrincipalId(req.principal),
      displayName: req.principal,
    );
    return _principal;
  }

  @override
  Future<void> logout(String hubUrl) async {
    calls.add('logout:$hubUrl');
    _hub = null;
    _principal = null;
  }

  @override
  Future<List<NodeDescriptor>> listNodes() async {
    calls.add('listNodes');
    if (failNodes) throw StateError('SocketException: connection refused');
    return nodes;
  }

  /// What [hubInfo] returns; `null` makes it throw [hubInfoError].
  HubInfo? hub;
  Object hubInfoError = const HubTooOldException(
    'The Hub is older than 1.66.0 and cannot describe itself; '
    'upgrade it to see hub info.',
  );

  @override
  Future<HubInfo> hubInfo() async {
    calls.add('hubInfo');
    final info = hub;
    if (info == null) throw hubInfoError;
    return info;
  }

  @override
  Future<List<DetachedSessionInfo>> listSessions(String nodeId) async {
    calls.add('listSessions:$nodeId');
    if (failSessions) throw StateError('SocketException: connection refused');
    return sessions;
  }

  @override
  Future<DashboardActionResult> detachSession(
    String nodeId,
    String sessionRef, {
    Duration? timeout,
  }) async {
    calls.add('detach:$nodeId:$sessionRef');
    return DashboardActionResult(
      ok: true,
      message: 'Session $sessionRef detached',
    );
  }

  @override
  Future<DashboardActionResult> killSession(
    String nodeId,
    String sessionRef,
  ) async {
    calls.add('kill:$nodeId:$sessionRef');
    return DashboardActionResult(
      ok: true,
      message: 'Session $sessionRef terminated',
    );
  }

  @override
  Future<void> newSession(String nodeId) async {
    calls.add('new:$nodeId');
  }

  @override
  Future<void> resumeSession(String nodeId, String sessionRef) async {
    calls.add('resume:$nodeId:$sessionRef');
  }

  @override
  Future<void> peekSession(String nodeId, String sessionRef) async {
    calls.add('peek:$nodeId:$sessionRef');
  }

  // ---- Tunnels -------------------------------------------------------------

  @override
  Future<List<TunnelInfo>> listTunnels() async {
    calls.add('listTunnels');
    return tunnels;
  }

  @override
  Future<DashboardActionResult> openTunnel({
    required String nodeId,
    required int targetPort,
    int? publicPort,
    bool local = false,
    bool secure = false,
    TunnelProtocol protocol = TunnelProtocol.tcp,
    TunnelCacheOptions? cache,
  }) async {
    calls.add(
      'openTunnel:$nodeId:$targetPort:${publicPort ?? '-'}:$local:$secure'
      '${protocol == TunnelProtocol.tcp ? '' : ':${protocol.wireName}'}'
      '${cache == null ? '' : ':cache${cache.cachePrivate ? '+private' : ''}'}',
    );
    return const DashboardActionResult(ok: true, message: 'Tunnel opened');
  }

  @override
  Future<DashboardActionResult> closeTunnel(String tunnelRef) async {
    calls.add('closeTunnel:$tunnelRef');
    return const DashboardActionResult(ok: true, message: 'Tunnel closed.');
  }

  // ---- Drive ---------------------------------------------------------------

  @override
  Future<List<MountRecord>> listMounts() async {
    calls.add('listMounts');
    return mounts;
  }

  @override
  Future<MountRecord> mountDirectory({
    required String localDir,
    required String target,
    String? name,
    bool rw = false,
    bool initialSync = true,
    List<String> include = const [],
    List<String> exclude = const [],
  }) async {
    calls.add('mountDirectory:$localDir:$target:$rw');
    return mounts.isNotEmpty ? mounts.first : mountRecord('m1');
  }

  @override
  Future<MountRecord> mountGit({
    required String url,
    required String target,
    String? name,
    String? branch,
    int? depth,
    bool rw = false,
  }) async {
    calls.add('mountGit:$url:$target:$rw');
    return mounts.isNotEmpty ? mounts.first : mountRecord('m1', git: true);
  }

  @override
  Future<SyncOutcome> syncMount(
    String mountId, {
    DriveSyncDirection direction = DriveSyncDirection.auto,
  }) async {
    calls.add('syncMount:$mountId:${direction.name}');
    return SyncOutcome(record: mountRecord(mountId));
  }

  @override
  Future<DriveChanges> mountConflicts(
    String mountId, {
    bool includeDiffs = false,
  }) async {
    calls.add('mountConflicts:$mountId');
    return changes;
  }

  @override
  Future<FileDiff> diffFile(String mountId, String path) async {
    calls.add('diffFile:$mountId:$path');
    return FileDiff(path: path);
  }

  @override
  Future<SyncOutcome> resolveMount(
    String mountId, {
    required String strategy,
  }) async {
    calls.add('resolveMount:$mountId:$strategy');
    return SyncOutcome(record: mountRecord(mountId));
  }

  @override
  Future<FileResolveOutcome> resolveFile(
    String mountId,
    String path, {
    required String strategy,
  }) async {
    calls.add('resolveFile:$mountId:$path:$strategy');
    return FileResolveOutcome(
      record: mountRecord(mountId),
      path: path,
      strategy: strategy,
      converged: true,
    );
  }

  @override
  Future<MountRecord> remount(String mountId) async {
    calls.add('remount:$mountId');
    return mountRecord(mountId);
  }

  @override
  Future<DashboardActionResult> unmount(
    String mountId, {
    bool syncFirst = false,
    bool keepRemote = true,
  }) async {
    calls.add('unmount:$mountId:$syncFirst:$keepRemote');
    return DashboardActionResult(ok: true, message: 'Unmounted $mountId.');
  }

  @override
  Future<void> watchMount(String mountId) async {
    calls.add('watchMount:$mountId');
  }

  // ---- Drive credentials ---------------------------------------------------

  List<DriveCredentialEntry> gitCredentials = const [];

  /// When true, [listGitCredentials] throws (to exercise TUI error handling).
  bool failCredentials = false;

  /// When set, [listGitCredentials] waits for it (a slow node).
  Future<void>? credentialsGate;

  @override
  Future<List<DriveCredentialEntry>> listGitCredentials(String nodeId) async {
    calls.add('listGitCredentials:$nodeId');
    await credentialsGate;
    if (failCredentials) throw StateError('boom: node unreachable');
    return gitCredentials;
  }

  @override
  Future<DashboardActionResult> addGitCredential(
    String nodeId, {
    required String host,
    String? pat,
    String? username,
    String? password,
  }) async {
    calls.add(
      'addGitCredential:$nodeId:$host:${pat != null ? 'pat' : 'userpass'}',
    );
    return const DashboardActionResult(ok: true, message: 'Stored credential.');
  }

  @override
  Future<DashboardActionResult> removeGitCredential(
    String nodeId, {
    required String host,
  }) async {
    calls.add('removeGitCredential:$nodeId:$host');
    return const DashboardActionResult(
      ok: true,
      message: 'Removed credential.',
    );
  }

  // ---- AI ------------------------------------------------------------------

  @override
  Future<AiConfigDescription> aiDescribe() async {
    calls.add('aiDescribe');
    return aiDescription ?? aiDesc();
  }

  @override
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
  }) async {
    calls.add(
      'aiConfig:${provider?.wireName ?? '-'}:${model ?? '-'}:'
      '${apiKey == null ? '-' : 'key'}:${mode?.wireName ?? '-'}',
    );
  }

  @override
  Future<List<AiModelCheck>> aiTest() async {
    calls.add('aiTest');
    return aiChecks;
  }

  @override
  Future<void> close() async => calls.add('close');
}

// ---- Helpers ---------------------------------------------------------------

String frameText(ScreenBuffer? f) {
  if (f == null) return '';
  final rows = <String>[];
  for (var y = 0; y < f.height; y++) {
    final sb = StringBuffer();
    for (var x = 0; x < f.width; x++) {
      sb.write(f.cellAt(x, y).char);
    }
    rows.add(sb.toString());
  }
  return rows.join('\n');
}

Future<void> pump([int times = 8]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Presses a bare Escape the way a real terminal sends it — a lone ESC byte
/// with nothing after it — and waits for the app to time it out into Escape.
Future<void> pressEscape(FakeTerminal term) async {
  term.send(const [27]);
  await Future<void>.delayed(KeyDecoder.escapeTimeout * 2);
  await pump();
}

NodeDescriptor node(
  String id, {
  bool online = true,
  Map<String, String> labels = const {},
}) => NodeDescriptor(
  id: NodeId(id),
  displayName: id,
  online: online,
  platform: const PlatformInfo(
    os: 'linux',
    arch: 'x64',
    agentVersion: '1.0.0',
    hostname: 'host',
  ),
  labels: labels,
);

DetachedSessionInfo session(
  String shortId, {
  String nodeId = 'web-01',
  DateTime? created,
  DateTime? expiresAt,
  SessionState state = SessionState.detached,
}) => DetachedSessionInfo(
  sessionId: '${shortId}0000',
  shortId: shortId,
  nodeId: nodeId,
  ownerUserId: 'alice',
  mode: SessionMode.shell,
  createdAt: created ?? DateTime.utc(2020, 1, 1, 0),
  expiresAt: expiresAt,
  state: state,
);

TunnelInfo tunnelInfo(
  String id, {
  String nodeId = 'web-01',
  int publicPort = 20010,
  int targetPort = 5432,
  bool secure = false,
}) => TunnelInfo(
  tunnelId: '${id}00000000',
  nodeId: nodeId,
  ownerUserId: 'alice',
  targetHost: 'localhost',
  targetPort: targetPort,
  publicHost: 'hub.example.com',
  publicPort: publicPort,
  secure: secure,
  createdAt: DateTime.utc(2020, 1, 1),
);

MountRecord mountRecord(
  String id, {
  String nodeId = 'web-01',
  bool git = false,
  bool rw = true,
  SyncStatus status = SyncStatus.clean,
}) => MountRecord(
  id: id,
  nodeId: nodeId,
  name: id,
  kind: git ? 'git' : 'dir',
  remotePath: '/srv/app',
  readWrite: rw,
  driveId: 'drive-$id',
  mountedAt: DateTime.utc(2020, 1, 1),
  localPath: git ? null : '/home/alice/src',
  gitUrl: git ? 'https://example.com/repo.git' : null,
  syncState: SyncState(baselineRef: SyncRef.git('0'), status: status),
);

AiConfigDescription aiDesc({
  AiProviderKind? provider = AiProviderKind.anthropic,
  String? model = 'claude-opus-4-8',
  bool keySet = true,
}) => AiConfigDescription(
  path: '/home/alice/.omnyshell/ai.yaml',
  fileExists: true,
  provider: provider,
  providerFromEnv: false,
  model: model,
  modelFromEnv: false,
  modelFromDefault: false,
  plannerModel: null,
  plannerFromDefault: false,
  executorModel: null,
  explainerModel: null,
  mode: AgentMode.standard,
  language: null,
  baseUrl: null,
  maxSteps: 40,
  keySet: keySet,
  keyFromEnv: false,
  keyEnvVar: 'ANTHROPIC_API_KEY',
);

const enter = [13];
const ctrlQ = [17];
const tab = [9];
const down = [27, 91, 66];
const left = [27, 91, 68];
const home = [27, 91, 72];
const end = [27, 91, 70];

DashboardApp _app(FakeTerminal term, FakeDashboardBackend backend) =>
    DashboardApp(
      terminal: term,
      backend: backend,
      clock: () => DateTime.utc(2020, 1, 1, 1),
    );

void main() {
  test(
    'login screen lists saved sessions and connect opens the nodes list',
    () async {
      final term = FakeTerminal();
      final backend = FakeDashboardBackend(
        auth: const AuthSnapshot(
          defaultHub: 'wss://hub:8443',
          logins: [
            SavedLogin(
              hubUrl: 'wss://hub:8443',
              principal: 'alice',
              method: 'token',
              isDefault: true,
            ),
          ],
        ),
        nodes: [node('web-01'), node('db-02', online: false)],
      );
      final running = _app(term, backend).run();
      await pump();

      expect(frameText(term.lastFrame), contains('OmnyShell Dashboard'));
      expect(frameText(term.lastFrame), contains('alice@wss://hub:8443'));

      // Focus starts on the saved login; Enter connects.
      term.send(enter);
      await pump();

      expect(backend.calls, contains('connect:wss://hub:8443'));
      expect(backend.calls, contains('listNodes'));
      final text = frameText(term.lastFrame);
      expect(text, contains('web-01'));
      expect(text, contains('db-02'));
      expect(text, contains('linux/x64'));

      term.send(ctrlQ);
      await running;
      expect(backend.calls, contains('close'));
    },
  );

  test('opening a node shows its info and sessions', () async {
    final term = FakeTerminal();
    final backend = FakeDashboardBackend(
      auth: const AuthSnapshot(
        logins: [
          SavedLogin(hubUrl: 'wss://h', principal: 'alice', method: 'token'),
        ],
      ),
      nodes: [
        node('web-01', labels: {'env': 'prod'}),
      ],
      sessions: [session('a1b2c3d4'), session('e5f6a7b8')],
    );
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send(enter); // open node web-01
    await pump();

    expect(backend.calls, contains('listSessions:web-01'));
    final text = frameText(term.lastFrame);
    // The node's tab strip, with a one-line summary above the sessions (the
    // full detail, labels included, is on the Info tab).
    expect(text, contains('web-01   s Sessions'));
    expect(text, contains('online  ·  linux/x64  ·  host  ·  agent 1.0.0'));
    expect(text, contains('a1b2c3d4'));
    expect(text, contains('e5f6a7b8'));
    // Age is 1h given the injected clock and createdAt.
    expect(text, contains('1h'));

    term.send(ctrlQ);
    await running;
  });

  test(
    'session actions dispatch to the backend for the selected session',
    () async {
      final term = FakeTerminal();
      final backend = FakeDashboardBackend(
        auth: const AuthSnapshot(
          logins: [
            SavedLogin(hubUrl: 'wss://h', principal: 'alice', method: 'token'),
          ],
        ),
        nodes: [node('web-01')],
        // a1 is newer, so with no last-interacted session it sorts first and
        // e5 is the second row.
        sessions: [
          session('a1b2c3d4', created: DateTime.utc(2020, 1, 1, 0, 30)),
          session('e5f6a7b8', created: DateTime.utc(2020, 1, 1, 0, 0)),
        ],
      );
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send(enter); // open node
      await pump();

      // Move to the second session and detach it.
      term.send(down);
      await pump();
      term.send('d'.codeUnits);
      await pump();
      expect(backend.calls, contains('detach:web-01:e5f6a7b8'));

      // Resume the second session (Enter).
      term.send(enter);
      await pump();
      expect(backend.calls, contains('resume:web-01:e5f6a7b8'));

      // Open a brand-new shell on the node ('n').
      term.send('n'.codeUnits);
      await pump();
      expect(backend.calls, contains('new:web-01'));

      // Peek it.
      term.send('p'.codeUnits);
      await pump();
      expect(backend.calls, contains('peek:web-01:e5f6a7b8'));

      // Terminate needs a confirmation.
      term.send('k'.codeUnits);
      await pump();
      expect(frameText(term.lastFrame), contains('Terminate session?'));
      term.send('y'.codeUnits);
      await pump();
      expect(backend.calls, contains('kill:web-01:e5f6a7b8'));

      term.send(ctrlQ);
      await running;
    },
  );

  test('Esc/Left returns to the node list and L logs out', () async {
    final term = FakeTerminal();
    final backend = FakeDashboardBackend(
      auth: const AuthSnapshot(
        logins: [
          SavedLogin(hubUrl: 'wss://h', principal: 'alice', method: 'token'),
        ],
      ),
      nodes: [node('web-01')],
      sessions: [session('a1b2c3d4')],
    );
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send(enter); // open node
    await pump();
    expect(frameText(term.lastFrame), contains('web-01   s Sessions'));

    term.send(left); // back to nodes
    await pump();
    expect(frameText(term.lastFrame), contains('Nodes'));

    term.send('L'.codeUnits); // logout
    await pump();
    expect(backend.calls, contains('logout:wss://h'));
    expect(frameText(term.lastFrame), contains('OmnyShell Dashboard'));

    term.send(ctrlQ);
    await running;
  });

  test(
    'a failed node refresh keeps the last list and shows a warning',
    () async {
      final term = FakeTerminal();
      final backend = FakeDashboardBackend(
        auth: const AuthSnapshot(
          logins: [
            SavedLogin(hubUrl: 'wss://h', principal: 'alice', method: 'token'),
          ],
        ),
        nodes: [node('web-01'), node('db-02')],
      );
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect -> nodes
      await pump();
      expect(frameText(term.lastFrame), contains('web-01'));

      // Next refresh fails but the connection is still up: keep the list.
      backend.failNodes = true;
      term.send('r'.codeUnits);
      await pump();
      final text = frameText(term.lastFrame);
      expect(text, contains('web-01')); // list retained
      expect(text, contains('refresh failed')); // soft warning
      expect(frameText(term.lastFrame), isNot(contains('OmnyShell Dashboard')));

      term.send(ctrlQ);
      await running;
    },
  );

  test('a dropped connection returns to the login screen', () async {
    final term = FakeTerminal();
    final backend = FakeDashboardBackend(
      auth: const AuthSnapshot(
        logins: [
          SavedLogin(hubUrl: 'wss://h', principal: 'alice', method: 'token'),
        ],
      ),
      nodes: [node('web-01')],
    );
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect -> nodes
    await pump();

    // Simulate the Hub connection dropping, then a refresh.
    backend.connected = false;
    backend.failNodes = true;
    term.send('r'.codeUnits);
    await pump();
    final text = frameText(term.lastFrame);
    expect(text, contains('OmnyShell Dashboard')); // back on login
    expect(text, contains('Connection to the Hub was lost'));

    term.send(ctrlQ);
    await running;
  });

  test('an expired session lease renders as "expired"', () async {
    final term = FakeTerminal();
    final backend = FakeDashboardBackend(
      auth: const AuthSnapshot(
        logins: [
          SavedLogin(hubUrl: 'wss://h', principal: 'alice', method: 'token'),
        ],
      ),
      nodes: [node('web-01')],
      sessions: [
        session('a1b2c3d4', expiresAt: DateTime.utc(2019, 12, 31)), // past
      ],
    );
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send(enter); // open node
    await pump();
    expect(frameText(term.lastFrame), contains('expired'));

    term.send(ctrlQ);
    await running;
  });

  test('n cancels the terminate confirmation without killing', () async {
    final term = FakeTerminal();
    final backend = FakeDashboardBackend(
      auth: const AuthSnapshot(
        logins: [
          SavedLogin(hubUrl: 'wss://h', principal: 'alice', method: 'token'),
        ],
      ),
      nodes: [node('web-01')],
      sessions: [session('a1b2c3d4')],
    );
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send(enter); // open node
    await pump();

    term.send('k'.codeUnits); // ask to terminate
    await pump();
    expect(frameText(term.lastFrame), contains('Terminate session?'));

    term.send('n'.codeUnits); // cancel
    await pump();
    expect(frameText(term.lastFrame), isNot(contains('Terminate session?')));
    expect(backend.calls.where((c) => c.startsWith('kill:')), isEmpty);

    term.send(ctrlQ);
    await running;
  });

  // ---- Tunnels / Drive / AI tabs -------------------------------------------

  FakeDashboardBackend connectedBackend() => FakeDashboardBackend(
    auth: const AuthSnapshot(
      logins: [
        SavedLogin(hubUrl: 'wss://h', principal: 'alice', method: 'token'),
      ],
    ),
    nodes: [node('web-01')],
  );

  test('Tab switches to the tunnels tab and lists tunnels', () async {
    final term = FakeTerminal();
    final backend = connectedBackend()..tunnels = [tunnelInfo('t1')];
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send(tab); // nodes -> tunnels
    await pump();

    expect(backend.calls, contains('listTunnels'));
    final text = frameText(term.lastFrame);
    expect(text, contains('Tunnels'));
    expect(text, contains('t1000000'));
    expect(text, contains('hub.example.com:20010'));

    term.send(ctrlQ);
    await running;
  });

  test('the tunnels list shows cache usage', () async {
    final term = FakeTerminal(cols: 140);
    final backend = connectedBackend()
      ..tunnels = [
        TunnelInfo(
          tunnelId: 'c1000000',
          nodeId: 'web-01',
          ownerUserId: 'alice',
          targetHost: 'localhost',
          targetPort: 80,
          publicHost: 'hub.example.com',
          publicPort: 20011,
          protocol: TunnelProtocol.http,
          cache: const TunnelCacheOptions(maxBytes: 32 * 1024 * 1024),
          cacheStats: const TunnelCacheStats(hits: 5, misses: 1),
          createdAt: DateTime.utc(2020),
        ),
      ];
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send(tab); // nodes -> tunnels
    await pump();
    final text = frameText(term.lastFrame);
    expect(text, contains('http://hub.example.com:20011'));
    expect(text, contains('cache 0 B/32 MiB · 5 hit / 1 miss'));

    term.send(ctrlQ);
    await running;
  });

  test('tunnel open form dispatches openTunnel', () async {
    final term = FakeTerminal();
    final backend = connectedBackend();
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send('2'.codeUnits); // jump to tunnels tab
    await pump();
    term.send('o'.codeUnits); // open form
    await pump();
    expect(frameText(term.lastFrame), contains('Open tunnel'));

    term.send(down); // focus: Local -> Node
    await pump();
    term.send('web-01'.codeUnits);
    await pump();
    term.send(enter); // -> Target port
    await pump();
    term.send('5432'.codeUnits);
    await pump();
    term.send(enter); // -> Public port
    await pump();
    term.send(enter); // -> Secure
    await pump();
    term.send(enter); // -> HTTP
    await pump();
    term.send(enter); // -> HTTP cache
    await pump();
    term.send(enter); // -> Cache private
    await pump();
    term.send(enter); // -> Submit
    await pump();
    term.send(enter); // submit
    await pump();

    expect(backend.calls, contains('openTunnel:web-01:5432:-:false:false'));

    term.send(ctrlQ);
    await running;
  });

  test('tunnel open form passes the HTTP protocol when toggled', () async {
    final term = FakeTerminal();
    final backend = connectedBackend();
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send('2'.codeUnits); // jump to tunnels tab
    await pump();
    term.send('o'.codeUnits); // open form
    await pump();
    expect(frameText(term.lastFrame), contains('HTTP headers:'));

    term.send(down); // Local -> Node
    await pump();
    term.send('web-01'.codeUnits);
    await pump();
    term.send(enter); // -> Target port
    await pump();
    term.send('8080'.codeUnits);
    await pump();
    term.send(enter); // -> Public port
    await pump();
    term.send(enter); // -> Secure
    await pump();
    term.send(' '.codeUnits); // toggle Secure on
    await pump();
    term.send(enter); // -> HTTP
    await pump();
    term.send(' '.codeUnits); // toggle HTTP on
    await pump();
    term.send(enter); // -> HTTP cache
    await pump();
    term.send(enter); // -> Cache private
    await pump();
    term.send(enter); // -> Submit
    await pump();
    term.send(enter); // submit
    await pump();

    expect(backend.calls, contains('openTunnel:web-01:8080:-:false:true:http'));

    term.send(ctrlQ);
    await running;
  });

  test('the cache toggles open a cached HTTP tunnel', () async {
    final term = FakeTerminal();
    final backend = connectedBackend();
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send('2'.codeUnits); // tunnels tab
    await pump();
    term.send('o'.codeUnits); // open form
    await pump();
    final form = frameText(term.lastFrame);
    expect(form, contains('HTTP cache:'));
    expect(form, contains('Cache private:'));

    term.send(down); // Local -> Node
    await pump();
    term.send('web-01'.codeUnits);
    await pump();
    term.send(enter); // -> Target port
    await pump();
    term.send('80'.codeUnits);
    await pump();
    for (var i = 0; i < 4; i++) {
      term.send(enter); // -> Public port, Secure, HTTP, HTTP cache
      await pump();
    }
    term.send(enter); // -> Cache private
    await pump();
    term.send(' '.codeUnits); // Cache private on (implies cache + HTTP)
    await pump();
    term.send(enter); // -> Submit
    await pump();
    term.send(enter); // submit
    await pump();

    expect(
      backend.calls,
      contains('openTunnel:web-01:80:-:false:false:http:cache+private'),
    );

    term.send(ctrlQ);
    await running;
  });

  test(
    'node credentials: c opens the view and add dispatches addGitCredential',
    () async {
      final term = FakeTerminal();
      final backend = connectedBackend()
        ..gitCredentials = const [
          DriveCredentialEntry(
            host: 'github.com',
            description: 'GitPat(username: x-access-token, token: ***)',
          ),
        ];
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send(enter); // open node web-01
      await pump();
      term.send('c'.codeUnits); // open credentials view
      await pump();

      expect(backend.calls, contains('listGitCredentials:web-01'));
      final text = frameText(term.lastFrame);
      expect(text, contains('CREDENTIAL (yours, masked)'));
      expect(text, contains('github.com'));
      expect(text, contains('***')); // masked
      // The status bar summarizes the load.
      expect(text, contains('1 git credential on web-01'));

      // Add a PAT credential via the modal form.
      term.send('a'.codeUnits);
      await pump();
      expect(frameText(term.lastFrame), contains('Add git credential'));
      term.send('gitlab.com'.codeUnits); // host (field 0)
      await pump();
      term.send(enter); // -> user/pass toggle (leave off = PAT)
      await pump();
      term.send(enter); // -> PAT / password (secret)
      await pump();
      term.send('ghp_secret'.codeUnits);
      await pump();
      term.send(enter); // -> username (leave empty)
      await pump();
      term.send(enter); // -> submit row
      await pump();
      term.send(enter); // submit
      await pump();

      expect(backend.calls, contains('addGitCredential:web-01:gitlab.com:pat'));

      term.send(ctrlQ);
      await running;
    },
  );

  test(
    'node credentials: an empty list reports "no credentials" in the status',
    () async {
      final term = FakeTerminal();
      final backend = connectedBackend(); // no credentials registered
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send(enter); // open node web-01
      await pump();
      term.send('c'.codeUnits); // open credentials -> empty list
      await pump();

      expect(backend.calls, contains('listGitCredentials:web-01'));
      final text = frameText(term.lastFrame);
      // Status summarizes the (empty) load instead of sticking on "Loading…".
      expect(text, contains('No git credentials for you on web-01'));
      expect(text, isNot(contains('Loading credentials')));

      term.send(ctrlQ);
      await running;
    },
  );

  test(
    'node credentials: a backend error is shown and the TUI stays interactive',
    () async {
      final term = FakeTerminal();
      final backend = connectedBackend()..failCredentials = true;
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send(enter); // open node web-01
      await pump();
      term.send('c'.codeUnits); // open credentials -> load throws
      await pump();

      expect(backend.calls, contains('listGitCredentials:web-01'));
      // The error is surfaced on screen rather than freezing on "Loading…".
      expect(frameText(term.lastFrame).toLowerCase(), contains('failed'));

      // Still interactive: Left/Esc leaves the node for the node list.
      term.send(left);
      await pump();
      expect(frameText(term.lastFrame), contains('1 node(s), 1 online'));

      term.send(ctrlQ);
      await running;
    },
  );

  test(
    'node credentials: remove asks to confirm then dispatches removeGitCredential',
    () async {
      final term = FakeTerminal();
      final backend = connectedBackend()
        ..gitCredentials = const [
          DriveCredentialEntry(
            host: 'github.com',
            description: 'GitPat(username: x-access-token, token: ***)',
          ),
        ];
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send(enter); // open node
      await pump();
      term.send('c'.codeUnits); // credentials view
      await pump();

      term.send('x'.codeUnits); // remove selected
      await pump();
      expect(frameText(term.lastFrame), contains('Remove credential?'));
      term.send('y'.codeUnits); // confirm
      await pump();
      expect(backend.calls, contains('removeGitCredential:web-01:github.com'));

      term.send(ctrlQ);
      await running;
    },
  );

  group('node info tab', () {
    NodeDescriptor detailedNode() => NodeDescriptor(
      id: NodeId('web-01'),
      displayName: 'Web server',
      online: true,
      platform: const PlatformInfo(
        os: 'linux',
        arch: 'x64',
        agentVersion: omnyShellVersion,
        hostname: 'menuici-sites',
        osVersion:
            '6.1.0-53-cloud-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.187-1 '
            '(2026-09-07)',
        cpuCount: 8,
        runtimeVersion: '3.13.0 (stable)',
      ),
      labels: const {'region': 'eu', 'env': 'prod'},
      capabilities: const NodeCapabilities(
        shells: ['bash', 'sh'],
        features: ['exec', 'shell'],
        maxSessions: 50,
      ),
    );

    test('i on the node list opens Info with every node field', () async {
      final term = FakeTerminal(cols: 80, rows: 40);
      final backend = connectedBackend()..nodes = [detailedNode()];
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('i'.codeUnits); // open web-01 straight onto Info
      await pump();

      final text = frameText(term.lastFrame);
      expect(text, contains('s Sessions'));
      expect(text, contains('i Info'));
      expect(text, contains('c Credentials'));
      expect(text, contains('Web server'));
      expect(text, contains('6.1.0-53-cloud-amd64 #1 SMP PREEMPT_DYNAMIC'));
      // The long OS version wraps onto a continuation line at 80 columns
      // rather than being clipped.
      expect(text, contains('(2026-09-07)'));
      expect(text, isNot(contains('PREEMPT_DYNAMIC Debian 6.1.187-1 (2026')));
      expect(text, contains('menuici-sites'));
      expect(text, contains('$omnyShellVersion (same as this client)'));
      expect(text, contains('3.13.0 (stable)'));
      expect(text, contains('bash, sh'));
      expect(text, contains('— (reached through the Hub)'));
      expect(text, contains('region'));
      expect(text, contains('wss://h'));
      expect(RegExp(r'CPUs\s+8').hasMatch(text), isTrue);
      // Info renders the listed descriptor: no session RPC until asked.
      expect(backend.calls.where((c) => c.startsWith('listSessions')), isEmpty);

      term.send('s'.codeUnits); // -> Sessions tab loads the sessions
      await pump();
      expect(backend.calls, contains('listSessions:web-01'));

      term.send(ctrlQ);
      await running;
    });

    test('an older agent shows its missing fields as not reported', () async {
      final term = FakeTerminal(cols: 100, rows: 40);
      final backend = connectedBackend(); // node('web-01'): agent 1.0.0
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send(enter); // open node (Sessions)
      await pump();
      term.send('i'.codeUnits); // -> Info tab
      await pump();

      final text = frameText(term.lastFrame);
      expect(text, contains('1.0.0 (this client: $omnyShellVersion)'));
      expect(RegExp(r'OS version\s+— \(not reported\)').hasMatch(text), isTrue);
      expect(text, contains('— (none registered)'));

      term.send(ctrlQ);
      await running;
    });

    test('scrolls on a short terminal and r refreshes the node', () async {
      final term = FakeTerminal(cols: 100, rows: 14);
      final backend = connectedBackend()..nodes = [detailedNode()];
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('i'.codeUnits);
      await pump();
      expect(frameText(term.lastFrame), isNot(contains('Signed in as')));

      term.send(end);
      await pump();
      expect(frameText(term.lastFrame), contains('Signed in as'));

      backend.nodes = [detailedNode().copyWith(online: false)];
      term.send('r'.codeUnits);
      await pump();
      // Checked before the next key, which clears transient messages.
      expect(frameText(term.lastFrame), contains('Node info refreshed.'));
      term.send(home);
      await pump();
      expect(frameText(term.lastFrame), contains('offline'));

      term.send(ctrlQ);
      await running;
    });

    test('r reports a node the Hub no longer lists', () async {
      final term = FakeTerminal(cols: 100, rows: 40);
      final backend = connectedBackend()..nodes = [detailedNode()];
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('i'.codeUnits);
      await pump();

      backend.nodes = const [];
      term.send('r'.codeUnits);
      await pump();
      final text = frameText(term.lastFrame);
      expect(text, contains('web-01 is no longer listed by the Hub.'));
      // The last-known descriptor stays on screen.
      expect(text, contains('menuici-sites'));

      term.send(ctrlQ);
      await running;
    });

    test('s / i / c move between the node tabs; sessions load once', () async {
      final term = FakeTerminal(cols: 100, rows: 40);
      final backend = connectedBackend()..nodes = [detailedNode()];
      int sessionLoads() =>
          backend.calls.where((c) => c == 'listSessions:web-01').length;
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('i'.codeUnits); // Info, sessions never loaded
      await pump();

      term.send('c'.codeUnits); // Info -> Credentials
      await pump();
      expect(backend.calls, contains('listGitCredentials:web-01'));
      expect(frameText(term.lastFrame), contains('CREDENTIAL (yours, masked)'));

      term.send('i'.codeUnits); // Credentials -> Info
      await pump();
      expect(frameText(term.lastFrame), contains('OS version'));
      expect(sessionLoads(), 0);

      // Sessions fetches them the first time: the node was opened onto Info.
      term.send('s'.codeUnits);
      await pump();
      expect(sessionLoads(), 1);
      expect(frameText(term.lastFrame), contains('No sessions on this node'));

      // Coming back to Sessions does not re-fetch; `r` does.
      term.send('i'.codeUnits);
      await pump();
      term.send('c'.codeUnits);
      await pump();
      term.send('s'.codeUnits);
      await pump();
      expect(sessionLoads(), 1);
      term.send('r'.codeUnits);
      await pump();
      expect(sessionLoads(), 2);

      term.send(ctrlQ);
      await running;
    });

    for (final tab in ['i', 'c']) {
      test('Esc on the ${tab == 'i' ? 'Info' : 'Credentials'} tab leaves the '
          'node with no RPC', () async {
        final term = FakeTerminal(cols: 100, rows: 40);
        final backend = connectedBackend()..nodes = [detailedNode()];
        final running = _app(term, backend).run();
        await pump();
        term.send(enter); // connect
        await pump();
        term.send('i'.codeUnits); // open straight onto Info
        await pump();
        if (tab == 'c') {
          term.send('c'.codeUnits);
          await pump();
        }
        final callsBefore = backend.calls.length;

        await pressEscape(term);
        expect(frameText(term.lastFrame), contains('1 node(s), 1 online'));
        expect(
          backend.calls.skip(callsBefore),
          isNot(contains(startsWith('listSessions'))),
        );

        term.send(ctrlQ);
        await running;
      });
    }

    test(
      'a credentials load that settles after leaving the tab is dropped',
      () async {
        final term = FakeTerminal(cols: 100, rows: 40);
        final gate = Completer<void>();
        final backend = connectedBackend()
          ..nodes = [detailedNode()]
          ..credentialsGate = gate.future
          ..gitCredentials = const [
            DriveCredentialEntry(
              host: 'github.com',
              description: 'GitPat(***)',
            ),
          ];
        final running = _app(term, backend).run();
        await pump();
        term.send(enter); // connect
        await pump();
        term.send('i'.codeUnits);
        await pump();
        term.send('c'.codeUnits); // starts the (gated) background load
        await pump();
        term.send('i'.codeUnits); // leave for Info before it settles
        await pump();

        gate.complete();
        await pump();
        final text = frameText(term.lastFrame);
        // Info's screen is untouched: no credentials summary over its status.
        expect(text, isNot(contains('git credential')));
        expect(text, contains('OS version'));

        term.send(ctrlQ);
        await running;
      },
    );

    test('long label keys and emoji wrap whole, by column', () async {
      final term = FakeTerminal(cols: 60, rows: 40);
      final backend = connectedBackend()
        ..nodes = [
          detailedNode().copyWith(
            labels: {
              'kubernetes.io/hostname': 'a',
              'kubernetes.io/arch': 'b',
              'Status': 'maintenance',
              'emoji': '🚀' * 50,
            },
          ),
        ];
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('i'.codeUnits);
      await pump();
      term.send(end);
      await pump();

      final frame = term.lastFrame!;
      final text = frameText(frame);
      // Both keys are told apart: shown whole in the value column.
      expect(text, contains('kubernetes.io/hostname = a'));
      expect(text, contains('kubernetes.io/arch = b'));
      // The value column is 60 - 18 - 1 = 41 columns and each rune takes one:
      // the line breaks at the space after "emoji =", then 41 rockets, then the
      // last 9 (cutting by UTF-16 units would fit only 20 and split a pair).
      final rows = text.split('\n');
      final first = rows.indexWhere((r) => r.trimRight().endsWith('emoji ='));
      expect(first, greaterThanOrEqualTo(0));
      expect(rows[first + 1].trim(), '🚀' * 41);
      expect(rows[first + 2].trim(), '🚀' * 9);
      expect(text, isNot(contains('\u{FFFD}'))); // no split surrogate pair

      // A label keyed "Status" is not coloured like the node's status.
      final y = rows.indexWhere((r) => r.contains('Status = maintenance'));
      final x = rows[y].indexOf('maintenance');
      expect(frame.cellAt(x, y).style.fg, const Color.indexed(252));

      term.send(ctrlQ);
      await running;
    });

    test('an arrow key split across reads is not taken for Escape', () async {
      final term = FakeTerminal(cols: 100, rows: 40);
      final backend = connectedBackend()..nodes = [detailedNode()];
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('i'.codeUnits);
      await pump();

      // ESC, then the rest of Down (`[B`) in the next read, inside the timeout.
      term.send(const [27]);
      await pump();
      term.send(const [91, 66]);
      await Future<void>.delayed(KeyDecoder.escapeTimeout * 2);
      await pump();
      // Still on Info: an Escape would have gone back to Sessions.
      expect(frameText(term.lastFrame), contains('OS version'));
      expect(backend.calls.where((c) => c.startsWith('listSessions')), isEmpty);

      term.send(ctrlQ);
      await running;
    });

    test('a value longer than the column breaks mid-word', () async {
      final term = FakeTerminal(cols: 40, rows: 40);
      final backend = connectedBackend()
        ..nodes = [
          detailedNode().copyWith(labels: {'k': 'x' * 30}),
        ];
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('i'.codeUnits);
      await pump();

      // The value column is 40 - 18 - 1 = 21 wide: 21 x's, then the other 9.
      final rows = frameText(term.lastFrame).split('\n');
      final first = rows.indexWhere((r) => r.contains('x' * 21));
      expect(first, greaterThanOrEqualTo(0));
      expect(rows[first], isNot(contains('x' * 22)));
      expect(rows[first + 1].trim(), 'x' * 9);

      term.send(ctrlQ);
      await running;
    });
  });

  group('hub tab', () {
    HubInfo hubInfo({String version = omnyShellVersion}) => HubInfo(
      hubUid: 'hub_7f3a',
      version: version,
      protocolVersion: 1,
      minProtocolVersion: 1,
      platform: PlatformInfo(
        os: 'linux',
        arch: 'x64',
        agentVersion: version,
        hostname: 'hub-eu-1',
        osVersion: '6.1.0-53-cloud-amd64',
        cpuCount: 4,
        runtimeVersion: '3.13.0 (stable)',
      ),
      startedAt: DateTime.utc(2026, 10, 22, 8, 30),
      uptime: const Duration(days: 3, hours: 4, minutes: 12),
      nodes: 5,
      onlineNodes: 4,
      clients: 2,
      sessions: 7,
      tunnels: 1,
      tunnelPorts: '20000-20100',
      aiProvider: 'anthropic',
    );

    test('5 opens the Hub tab with the hub description', () async {
      final term = FakeTerminal(cols: 100, rows: 40);
      final backend = connectedBackend()..hub = hubInfo();
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('5'.codeUnits); // hub tab
      await pump();

      expect(backend.calls, contains('hubInfo'));
      final text = frameText(term.lastFrame);
      expect(text, contains('5 Hub'));
      expect(text, contains('wss://h'));
      expect(text, contains('hub_7f3a'));
      expect(text, contains('hub-eu-1'));
      expect(text, contains('6.1.0-53-cloud-amd64'));
      expect(RegExp(r'CPUs\s+4').hasMatch(text), isTrue);
      expect(text, contains('$omnyShellVersion (same as this client)'));
      expect(text, contains('3.13.0 (stable)'));
      expect(text, contains('2026-10-22 08:30 UTC'));
      expect(text, contains('3d 4h 12m'));
      expect(text, contains('5 (4 online)'));
      expect(text, contains('enabled (ports 20000-20100)'));
      expect(RegExp(r'AI default\s+anthropic').hasMatch(text), isTrue);

      // The status line names the Hub's version once the busy note clears.
      term.send(down);
      await pump();
      expect(frameText(term.lastFrame), contains('hub $omnyShellVersion'));

      term.send(ctrlQ);
      await running;
    });

    test('Tab cycles from AI to Hub and back to Nodes', () async {
      final term = FakeTerminal();
      final backend = connectedBackend()
        ..hub = hubInfo(version: '9.9.9')
        ..aiDescription = aiDesc();
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('4'.codeUnits); // ai tab
      await pump();
      term.send(tab); // ai -> hub
      await pump();
      expect(
        frameText(term.lastFrame),
        contains('9.9.9 (this client: $omnyShellVersion)'),
      );
      term.send(tab); // hub -> nodes (wraps)
      await pump();
      expect(frameText(term.lastFrame), contains('web-01'));

      term.send(ctrlQ);
      await running;
    });

    test('a Hub too old to answer says so', () async {
      final term = FakeTerminal();
      final backend = connectedBackend(); // hub == null: throws HubTooOld
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('5'.codeUnits);
      await pump();

      final text = frameText(term.lastFrame);
      expect(text, contains('older than 1.66.0'));
      expect(text, contains('No hub info — press r to retry.'));

      term.send(ctrlQ);
      await running;
    });

    test('a failed refresh keeps the last description', () async {
      final term = FakeTerminal(cols: 100, rows: 40);
      final backend = connectedBackend()..hub = hubInfo();
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('5'.codeUnits);
      await pump();

      backend
        ..hub = null
        ..hubInfoError = StateError('boom');
      term.send('r'.codeUnits);
      await pump();

      final text = frameText(term.lastFrame);
      expect(text, contains('Showing last results — refresh failed'));
      expect(text, contains('hub-eu-1'));
      expect(backend.calls.where((c) => c == 'hubInfo'), hasLength(2));

      term.send(ctrlQ);
      await running;
    });

    test('a reconnect never shows the previous Hub\'s description', () async {
      final term = FakeTerminal(cols: 100, rows: 40);
      final backend = connectedBackend()..hub = hubInfo();
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('5'.codeUnits);
      await pump();
      expect(frameText(term.lastFrame), contains('hub-eu-1'));

      // The connection drops: a failing refresh routes back to login.
      backend
        ..connected = false
        ..failNodes = true;
      term.send('1'.codeUnits);
      await pump();
      expect(frameText(term.lastFrame), contains('Connection to the Hub'));

      // Sign in again; this Hub cannot describe itself.
      backend
        ..connected = true
        ..failNodes = false
        ..hub = null
        ..hubInfoError = StateError('boom');
      term.send(enter);
      await pump();
      term.send('5'.codeUnits);
      await pump();

      final text = frameText(term.lastFrame);
      expect(text, isNot(contains('hub-eu-1')));
      expect(text, isNot(contains('Showing last results')));
      expect(text, contains('No hub info — press r to retry.'));

      term.send(ctrlQ);
      await running;
    });

    test('scrolls on a short terminal', () async {
      final term = FakeTerminal(cols: 100, rows: 12);
      final backend = connectedBackend()..hub = hubInfo();
      final running = _app(term, backend).run();
      await pump();
      term.send(enter); // connect
      await pump();
      term.send('5'.codeUnits);
      await pump();
      expect(frameText(term.lastFrame), contains('Identity'));
      expect(frameText(term.lastFrame), isNot(contains('AI default')));

      term.send(end);
      await pump();
      final text = frameText(term.lastFrame);
      expect(text, contains('AI default'));
      expect(text, isNot(contains('Identity')));

      term.send(ctrlQ);
      await running;
    });
  });

  test('tunnel close asks to confirm then dispatches closeTunnel', () async {
    final term = FakeTerminal();
    final backend = connectedBackend()..tunnels = [tunnelInfo('t1')];
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send('2'.codeUnits); // tunnels tab
    await pump();
    term.send('c'.codeUnits); // close selected
    await pump();
    expect(frameText(term.lastFrame), contains('Close tunnel?'));
    term.send(enter); // confirm
    await pump();

    expect(backend.calls, contains('closeTunnel:t1000000'));

    term.send(ctrlQ);
    await running;
  });

  test('drive tab: sync, open detail, and mount form', () async {
    final term = FakeTerminal();
    final backend = connectedBackend()..mounts = [mountRecord('web-01-app')];
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send('3'.codeUnits); // drive tab
    await pump();

    expect(backend.calls, contains('listMounts'));
    expect(frameText(term.lastFrame), contains('web-01-app'));

    term.send('s'.codeUnits); // sync selected
    await pump();
    expect(backend.calls, contains('syncMount:web-01-app:auto'));

    term.send(enter); // open detail
    await pump();
    expect(backend.calls, contains('mountConflicts:web-01-app'));
    expect(frameText(term.lastFrame), contains('Mount web-01-app'));

    term.send(left); // back to drive list
    await pump();

    term.send('m'.codeUnits); // mount form
    await pump();
    expect(frameText(term.lastFrame), contains('Mount'));
    term.send(down); // Git -> source
    await pump();
    term.send('./src'.codeUnits);
    await pump();
    term.send(enter); // -> target
    await pump();
    term.send('web-01:/srv/app'.codeUnits);
    await pump();
    term.send(enter); // -> name
    await pump();
    term.send(enter); // -> branch
    await pump();
    term.send(enter); // -> read-write
    await pump();
    term.send(enter); // -> submit
    await pump();
    term.send(enter); // submit
    await pump();

    expect(
      backend.calls,
      contains('mountDirectory:./src:web-01:/srv/app:false'),
    );

    term.send(ctrlQ);
    await running;
  });

  test('drive unmount confirms then dispatches', () async {
    final term = FakeTerminal();
    final backend = connectedBackend()..mounts = [mountRecord('web-01-app')];
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send('3'.codeUnits); // drive tab
    await pump();
    term.send('u'.codeUnits); // unmount
    await pump();
    expect(frameText(term.lastFrame), contains('Unmount?'));
    term.send(enter); // confirm
    await pump();

    expect(backend.calls, contains('unmount:web-01-app:false:true'));

    term.send(ctrlQ);
    await running;
  });

  test('ai tab renders config, test shows a report, edit saves', () async {
    final term = FakeTerminal();
    final backend = connectedBackend()
      ..aiDescription = aiDesc()
      ..aiChecks = [
        const AiModelCheck(model: 'claude-opus-4-8', ok: true, latencyMs: 120),
      ];
    final running = _app(term, backend).run();
    await pump();
    term.send(enter); // connect
    await pump();
    term.send('4'.codeUnits); // ai tab
    await pump();

    expect(backend.calls, contains('aiDescribe'));
    var text = frameText(term.lastFrame);
    expect(text, contains('AI configuration'));
    expect(text, contains('anthropic'));
    expect(text, contains('claude-opus-4-8'));

    term.send('t'.codeUnits); // run test
    await pump();
    expect(backend.calls, contains('aiTest'));
    text = frameText(term.lastFrame);
    expect(text, contains('AI test'));
    expect(text, contains('claude-opus-4-8'));

    term.send('q'.codeUnits); // close pager
    await pump();

    term.send('e'.codeUnits); // edit form
    await pump();
    expect(frameText(term.lastFrame), contains('AI config'));
    // Walk to the Submit row (10 fields) and submit with prefilled values.
    for (var i = 0; i < 11; i++) {
      term.send(enter);
      await pump();
    }

    expect(
      backend.calls,
      contains('aiConfig:anthropic:claude-opus-4-8:-:standard'),
    );

    term.send(ctrlQ);
    await running;
  });
}
