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
import 'package:omnyshell/src/application/client/ide/tui/terminal_driver.dart';
import 'package:omnyshell/src/domain/auth/principal.dart';
import 'package:omnyshell/src/domain/entities/detached_session_info.dart';
import 'package:omnyshell/src/domain/entities/node_descriptor.dart';
import 'package:omnyshell/src/domain/entities/platform_info.dart';
import 'package:omnyshell/src/domain/entities/session.dart';
import 'package:omnyshell/src/domain/entities/tunnel_info.dart';
import 'package:omnyshell/src/domain/value_objects/node_id.dart';
import 'package:omnyshell/src/domain/value_objects/principal_id.dart';
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
  }) async {
    calls.add(
      'openTunnel:$nodeId:$targetPort:${publicPort ?? '-'}:$local:$secure',
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
    expect(text, contains('Node web-01'));
    expect(text, contains('linux/x64'));
    expect(text, contains('env=prod'));
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
    expect(frameText(term.lastFrame), contains('Node web-01'));

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
    term.send(enter); // -> Submit
    await pump();
    term.send(enter); // submit
    await pump();

    expect(backend.calls, contains('openTunnel:web-01:5432:-:false:false'));

    term.send(ctrlQ);
    await running;
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
