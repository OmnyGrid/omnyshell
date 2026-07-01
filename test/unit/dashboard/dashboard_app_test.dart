import 'dart:async';

import 'package:omnyshell/src/application/client/dashboard/dashboard_app.dart';
import 'package:omnyshell/src/application/client/dashboard/dashboard_backend.dart';
import 'package:omnyshell/src/application/client/ide/tui/screen_buffer.dart';
import 'package:omnyshell/src/application/client/ide/tui/terminal_driver.dart';
import 'package:omnyshell/src/domain/auth/principal.dart';
import 'package:omnyshell/src/domain/entities/detached_session_info.dart';
import 'package:omnyshell/src/domain/entities/node_descriptor.dart';
import 'package:omnyshell/src/domain/entities/platform_info.dart';
import 'package:omnyshell/src/domain/entities/session.dart';
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

const enter = [13];
const ctrlQ = [17];
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
}
