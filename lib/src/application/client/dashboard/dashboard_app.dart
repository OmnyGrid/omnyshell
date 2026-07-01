import 'dart:async';

import '../../../domain/entities/node_descriptor.dart';
import '../../../domain/entities/detached_session_info.dart';
import '../../../domain/entities/session.dart' show SessionState;
import '../ide/tui/geometry.dart';
import '../ide/tui/key.dart';
import '../ide/tui/key_decoder.dart';
import '../ide/tui/screen_buffer.dart';
import '../ide/tui/style.dart';
import '../ide/tui/terminal_driver.dart';
import '../ide/widgets/input_dialog.dart';
import '../ide/widgets/palette.dart';
import 'dashboard_backend.dart';

/// Which screen the dashboard is currently showing.
enum _Screen { login, nodes, nodeDetail }

/// A pending yes/no confirmation (the terminate-session prompt). While active it
/// captures input: `y`/Enter runs [onYes], `n`/Esc dismisses it.
class _Confirm {
  _Confirm({required this.title, required this.hint, required this.onYes});

  final String title;
  final String hint;
  final Future<void> Function() onYes;
}

/// A full-screen TUI over the OmnyShell CLI: log in to a Hub, browse nodes, open
/// a node to see its info and sessions, and resume / peek / detach / terminate a
/// session — without typing individual commands.
///
/// Built on the same immediate-mode toolkit as the `:ide` command (`ScreenBuffer`,
/// `Rect`, `Style`, `KeyDecoder`) and driven through the injected
/// [DashboardBackend] port, so the whole app is `dart:io`-free and testable with a
/// fake terminal + fake backend. [run] takes over the terminal until the user
/// quits with `Ctrl-Q`, then restores it.
///
/// Resuming or peeking a session hands the real terminal to the backend's live
/// interactive runner: the app leaves the alt-screen, stops rendering, awaits the
/// backend, then re-enters and refreshes.
class DashboardApp {
  DashboardApp({
    required TerminalDriver terminal,
    required DashboardBackend backend,
    String? seedHub,
    String? seedPrincipal,
    DateTime Function()? clock,
  }) : _terminal = terminal,
       _backend = backend,
       _seedHub = seedHub,
       _seedPrincipal = seedPrincipal,
       _now = clock ?? DateTime.now;

  final TerminalDriver _terminal;
  final DashboardBackend _backend;
  final String? _seedHub;
  final String? _seedPrincipal;
  final DateTime Function() _now;

  final Completer<void> _done = Completer<void>();
  StreamSubscription<List<int>>? _inputSub;
  StreamSubscription<void>? _resizeSub;

  _Screen _screenId = _Screen.login;
  ScreenBuffer? _screen;

  String? _message;
  String? _messageHint;
  bool _messageIsError = false;
  bool _loading = false;
  _Confirm? _confirm;

  // Login screen state.
  AuthSnapshot _auth = const AuthSnapshot();
  int _loginFocus = 0;
  String _hub = '';
  String _principalInput = '';
  LoginMethod _method = LoginMethod.token;
  String _secret = '';
  bool _insecure = false;

  // Nodes screen state.
  List<NodeDescriptor> _nodes = const [];
  int _nodeSel = 0;
  int _nodeScroll = 0;

  // Node-detail screen state.
  NodeDescriptor? _currentNode;
  List<DetachedSessionInfo> _sessions = const [];
  int _sessionSel = 0;
  int _sessionScroll = 0;

  /// The `shortId` of the session the user last acted on (resumed / peeked /
  /// opened new); it sorts to the top and is highlighted, mirroring the web
  /// client's last-interacted affordance.
  String? _lastSessionRef;

  /// The last rendered frame (for tests); `null` before the first render.
  ScreenBuffer? get debugScreen => _screen;

  /// Runs the dashboard until the user quits, restoring the terminal afterwards.
  Future<void> run() async {
    _terminal.enter();
    try {
      _auth = await _safeAuthSnapshot();
      _prefillLogin();
      _render();
      _subscribe();
      await _done.future;
    } finally {
      await _unsubscribe();
      await _backend.close();
      _terminal.leave();
    }
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  // ---- Input plumbing ------------------------------------------------------

  void _subscribe() {
    final decoder = KeyDecoder();
    _inputSub = _terminal.input.listen(
      (bytes) async {
        final sub = _inputSub;
        sub?.pause();
        for (final key in decoder.decode(bytes)) {
          await _handleKey(key);
          if (_done.isCompleted) break;
        }
        if (!_done.isCompleted) _render();
        // Only resume if this is still the live subscription — a resume/peek
        // handoff cancels and re-creates it mid-chunk.
        if (!_done.isCompleted && identical(_inputSub, sub)) sub?.resume();
      },
      onError: (_) => _finish(),
      onDone: _finish,
    );
    _resizeSub = _terminal.resizeEvents.listen((_) {
      _terminal.invalidate();
      if (!_done.isCompleted) _render();
    });
  }

  Future<void> _unsubscribe() async {
    await _inputSub?.cancel();
    _inputSub = null;
    await _resizeSub?.cancel();
    _resizeSub = null;
  }

  /// Releases the terminal (leaves the alt-screen, stops rendering and input)
  /// for the duration of [body] — a live session resume or a screen peek that
  /// owns raw stdin/stdout — then reclaims and re-renders it.
  Future<void> _withTerminalReleased(Future<void> Function() body) async {
    await _unsubscribe();
    _terminal.leave();
    try {
      await body();
    } finally {
      _terminal.enter();
      _terminal.invalidate();
      _subscribe();
    }
  }

  // ---- Key routing ---------------------------------------------------------

  Future<void> _handleKey(KeyEvent key) async {
    final confirm = _confirm;
    if (confirm != null) {
      await _handleConfirmKey(key, confirm);
      return;
    }
    // A transient message clears on the next key press.
    if (_message != null) {
      _message = null;
      _messageHint = null;
      _messageIsError = false;
    }
    if (key.isCtrl('q')) {
      _finish();
      return;
    }
    switch (_screenId) {
      case _Screen.login:
        await _handleLoginKey(key);
      case _Screen.nodes:
        await _handleNodesKey(key);
      case _Screen.nodeDetail:
        await _handleNodeDetailKey(key);
    }
  }

  Future<void> _handleConfirmKey(KeyEvent key, _Confirm confirm) async {
    final yes =
        key.type == KeyType.enter ||
        (key.type == KeyType.char && (key.text == 'y' || key.text == 'Y'));
    final no =
        key.type == KeyType.escape ||
        (key.type == KeyType.char && (key.text == 'n' || key.text == 'N'));
    if (yes) {
      _confirm = null;
      await confirm.onYes();
    } else if (no) {
      _confirm = null;
    }
  }

  // ---- Login screen --------------------------------------------------------

  int get _loginFieldBase => _auth.logins.length;
  int get _loginItemCount => _auth.logins.length + 6;

  Future<void> _handleLoginKey(KeyEvent key) async {
    final n = _loginItemCount;
    switch (key.type) {
      case KeyType.up:
      case KeyType.backTab:
        _loginFocus = (_loginFocus - 1 + n) % n;
      case KeyType.down:
      case KeyType.tab:
        _loginFocus = (_loginFocus + 1) % n;
      case KeyType.enter:
        await _loginActivate();
      case KeyType.char:
        _loginChar(key.text);
      case KeyType.backspace:
        _loginBackspace();
      case KeyType.left:
      case KeyType.right:
        _loginToggle();
      default:
        break;
    }
  }

  Future<void> _loginActivate() async {
    final base = _loginFieldBase;
    if (_loginFocus < base) {
      await _connect(_auth.logins[_loginFocus].hubUrl);
      return;
    }
    switch (_loginFocus - base) {
      case 2:
        _loginToggle();
      case 4:
        _insecure = !_insecure;
      case 5:
        await _submitLogin();
      default:
        _loginFocus = (_loginFocus + 1) % _loginItemCount;
    }
  }

  void _loginChar(String ch) {
    if (ch.isEmpty) return;
    final f = _loginFocus - _loginFieldBase;
    if (f < 0) return;
    if ((f == 2 || f == 4) && ch == ' ') {
      _loginToggle();
      return;
    }
    switch (f) {
      case 0:
        _hub += ch;
      case 1:
        _principalInput += ch;
      case 3:
        _secret += ch;
    }
  }

  void _loginBackspace() {
    final f = _loginFocus - _loginFieldBase;
    switch (f) {
      case 0:
        if (_hub.isNotEmpty) _hub = _hub.substring(0, _hub.length - 1);
      case 1:
        if (_principalInput.isNotEmpty) {
          _principalInput = _principalInput.substring(
            0,
            _principalInput.length - 1,
          );
        }
      case 3:
        if (_secret.isNotEmpty) {
          _secret = _secret.substring(0, _secret.length - 1);
        }
    }
  }

  void _loginToggle() {
    final f = _loginFocus - _loginFieldBase;
    if (f == 2) {
      _method = _method == LoginMethod.token
          ? LoginMethod.publicKey
          : LoginMethod.token;
    } else if (f == 4) {
      _insecure = !_insecure;
    }
  }

  Future<void> _connect(String hubUrl) async {
    _setBusy('Connecting to $hubUrl…');
    try {
      await _backend.connect(hubUrl);
      await _gotoNodes();
    } on Object catch (e) {
      _setError('Login failed', e);
    }
  }

  /// Normalises a typed hub address: adds the `wss://` scheme when the user
  /// entered a bare `host:port` (matching the web client's convenience).
  static String _normalizeHub(String raw) {
    final hub = raw.trim();
    if (hub.isEmpty || hub.contains('://')) return hub;
    return 'wss://$hub';
  }

  Future<void> _submitLogin() async {
    final hub = _normalizeHub(_hub);
    final principal = _principalInput.trim();
    final secret = _secret.trim();
    if (hub.isEmpty || principal.isEmpty) {
      _setMessage('Hub and principal are required.', isError: true);
      return;
    }
    if (secret.isEmpty) {
      _setMessage(
        _method == LoginMethod.token
            ? 'A token is required.'
            : 'A key-file path is required.',
        isError: true,
      );
      return;
    }
    _setBusy('Authenticating…');
    try {
      await _backend.login(
        LoginRequest(
          hub: hub,
          principal: principal,
          method: _method,
          secret: secret,
          insecure: _insecure,
        ),
      );
      await _gotoNodes();
    } on Object catch (e) {
      _setError('Login failed', e);
    }
  }

  void _prefillLogin() {
    final logins = _auth.logins;
    final def =
        _auth.defaultHub ?? (logins.isNotEmpty ? logins.first.hubUrl : null);
    _hub = _seedHub ?? def ?? 'wss://127.0.0.1:8443';
    final match = logins.where((l) => l.hubUrl == def).toList();
    _principalInput =
        _seedPrincipal ?? (match.isNotEmpty ? match.first.principal : '');
    _method = LoginMethod.token;
    _secret = '';
    _insecure = match.isNotEmpty && match.first.insecure;
    // With saved logins, focus the first one (Enter = one-click reconnect);
    // otherwise focus the first empty form field (web-style auto-focus).
    _loginFocus = logins.isNotEmpty ? 0 : _firstEmptyLoginField();
  }

  /// The focus index of the first empty new-login field (hub → principal →
  /// secret), falling back to the Connect button when all are filled.
  int _firstEmptyLoginField() {
    final base = _loginFieldBase;
    if (_hub.trim().isEmpty) return base + 0;
    if (_principalInput.trim().isEmpty) return base + 1;
    if (_secret.trim().isEmpty) return base + 3;
    return base + 5;
  }

  // ---- Nodes screen --------------------------------------------------------

  Future<void> _handleNodesKey(KeyEvent key) async {
    switch (key.type) {
      case KeyType.up:
        _nodeSel = (_nodeSel - 1).clamp(0, _maxIndex(_nodes.length));
      case KeyType.down:
        _nodeSel = (_nodeSel + 1).clamp(0, _maxIndex(_nodes.length));
      case KeyType.pageUp:
        _nodeSel = (_nodeSel - 10).clamp(0, _maxIndex(_nodes.length));
      case KeyType.pageDown:
        _nodeSel = (_nodeSel + 10).clamp(0, _maxIndex(_nodes.length));
      case KeyType.home:
        _nodeSel = 0;
      case KeyType.end:
        _nodeSel = _maxIndex(_nodes.length);
      case KeyType.enter:
      case KeyType.right:
        await _openNode();
      case KeyType.char:
        switch (key.text) {
          case 'r':
            await _reloadNodes(busy: true);
          case 'L':
            await _logout();
        }
      default:
        break;
    }
  }

  Future<void> _openNode() async {
    if (_nodes.isEmpty) return;
    _currentNode = _nodes[_nodeSel.clamp(0, _maxIndex(_nodes.length))];
    _screenId = _Screen.nodeDetail;
    _sessionSel = 0;
    _sessionScroll = 0;
    await _reloadSessions(busy: true);
  }

  Future<void> _reloadNodes({bool busy = false}) async {
    if (busy) _setBusy('Loading nodes…');
    _loading = true;
    try {
      _nodes = await _backend.listNodes();
      if (_nodeSel > _maxIndex(_nodes.length)) {
        _nodeSel = _maxIndex(_nodes.length);
      }
    } on Object catch (e) {
      // Keep the last-known list on a refresh failure (soft-fail); only the
      // very first load has nothing to fall back to.
      if (_nodes.isEmpty) {
        _setError('Failed to list nodes', e);
      } else {
        _setError('Showing last results — refresh failed', e);
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> _gotoNodes() async {
    _screenId = _Screen.nodes;
    _nodeSel = 0;
    _nodeScroll = 0;
    await _reloadNodes();
  }

  Future<void> _logout() async {
    final hub = _backend.connectedHub;
    try {
      if (hub != null) await _backend.logout(hub);
    } on Object catch (e) {
      _setMessage('Logout failed: ${_short(e)}', isError: true);
    }
    _auth = await _safeAuthSnapshot();
    _prefillLogin();
    _screenId = _Screen.login;
    _setMessage('Logged out.');
  }

  // ---- Node-detail screen --------------------------------------------------

  Future<void> _handleNodeDetailKey(KeyEvent key) async {
    switch (key.type) {
      case KeyType.up:
        _sessionSel = (_sessionSel - 1).clamp(0, _maxIndex(_sessions.length));
      case KeyType.down:
        _sessionSel = (_sessionSel + 1).clamp(0, _maxIndex(_sessions.length));
      case KeyType.pageUp:
        _sessionSel = (_sessionSel - 10).clamp(0, _maxIndex(_sessions.length));
      case KeyType.pageDown:
        _sessionSel = (_sessionSel + 10).clamp(0, _maxIndex(_sessions.length));
      case KeyType.home:
        _sessionSel = 0;
      case KeyType.end:
        _sessionSel = _maxIndex(_sessions.length);
      case KeyType.escape:
      case KeyType.left:
        _screenId = _Screen.nodes;
      case KeyType.enter:
        await _resumeSelected();
      case KeyType.char:
        switch (key.text) {
          case 'n':
            await _newSession();
          case 'r':
            await _reloadSessions(busy: true);
          case 'p':
            await _peekSelected();
          case 'd':
            await _detachSelected();
          case 'k':
            _confirmKillSelected();
        }
      default:
        break;
    }
  }

  DetachedSessionInfo? get _selectedSession {
    if (_sessions.isEmpty) return null;
    return _sessions[_sessionSel.clamp(0, _maxIndex(_sessions.length))];
  }

  Future<void> _reloadSessions({bool busy = false}) async {
    final node = _currentNode;
    if (node == null) return;
    if (busy) _setBusy('Loading sessions…');
    _loading = true;
    try {
      _sessions = await _backend.listSessions(node.id.value);
      _applySessionOrder();
    } on Object catch (e) {
      // Keep the last-known sessions on a refresh failure (soft-fail).
      if (_sessions.isEmpty) {
        _setError('Failed to list sessions', e);
      } else {
        _setError('Showing last results — refresh failed', e);
      }
    } finally {
      _loading = false;
    }
  }

  /// Orders sessions to match the web client: the last-interacted one first,
  /// then those running a program, then detached before attached, then newest
  /// first. Preselects and keeps the last-interacted session in view.
  void _applySessionOrder() {
    bool running(DetachedSessionInfo s) => (s.currentCommand ?? '').isNotEmpty;
    final list = [..._sessions]
      ..sort((a, b) {
        final aLast = a.shortId == _lastSessionRef;
        final bLast = b.shortId == _lastSessionRef;
        if (aLast != bLast) return aLast ? -1 : 1;
        if (running(a) != running(b)) return running(a) ? -1 : 1;
        final aDet = a.state == SessionState.detached;
        final bDet = b.state == SessionState.detached;
        if (aDet != bDet) return aDet ? -1 : 1;
        return b.createdAt.compareTo(a.createdAt);
      });
    _sessions = list;
    final last = _lastSessionRef;
    if (last != null) {
      final i = _sessions.indexWhere((s) => s.shortId == last);
      if (i >= 0) _sessionSel = i;
    }
    if (_sessionSel > _maxIndex(_sessions.length)) {
      _sessionSel = _maxIndex(_sessions.length);
    }
  }

  Future<void> _newSession() async {
    final node = _currentNode;
    if (node == null) return;
    try {
      await _withTerminalReleased(() => _backend.newSession(node.id.value));
      await _reloadSessions();
      _setMessage('Returned from new session on ${node.id.value}.');
    } on Object catch (e) {
      await _reloadSessions();
      _setError('New session failed', e);
    }
  }

  Future<void> _resumeSelected() async {
    final s = _selectedSession;
    final node = _currentNode;
    if (s == null || node == null) return;
    _lastSessionRef = s.shortId;
    try {
      await _withTerminalReleased(
        () => _backend.resumeSession(node.id.value, s.shortId),
      );
      await _reloadSessions();
      _setMessage('Returned from session ${s.shortId}.');
    } on Object catch (e) {
      await _reloadSessions();
      _setError('Resume failed', e);
    }
  }

  Future<void> _peekSelected() async {
    final s = _selectedSession;
    final node = _currentNode;
    if (s == null || node == null) return;
    _lastSessionRef = s.shortId;
    try {
      await _withTerminalReleased(
        () => _backend.peekSession(node.id.value, s.shortId),
      );
    } on Object catch (e) {
      _setError('Peek failed', e);
    }
  }

  Future<void> _detachSelected() async {
    final s = _selectedSession;
    final node = _currentNode;
    if (s == null || node == null) return;
    _setBusy('Detaching ${s.shortId}…');
    try {
      final r = await _backend.detachSession(node.id.value, s.shortId);
      _setMessage(r.message, isError: !r.ok);
    } on Object catch (e) {
      _setError('Detach failed', e);
    }
    await _reloadSessions();
  }

  void _confirmKillSelected() {
    final s = _selectedSession;
    final node = _currentNode;
    if (s == null || node == null) return;
    _confirm = _Confirm(
      title: 'Terminate session?',
      hint:
          '${s.shortId} on ${node.id.value}  ·  y = terminate · n/Esc = cancel',
      onYes: () async {
        _setBusy('Terminating ${s.shortId}…');
        try {
          final r = await _backend.killSession(node.id.value, s.shortId);
          _setMessage(r.message, isError: !r.ok);
        } on Object catch (e) {
          _setError('Terminate failed', e);
        }
        await _reloadSessions();
      },
    );
  }

  // ---- Rendering -----------------------------------------------------------

  void _render() {
    final size = _terminal.size;
    final cols = size.cols;
    final rows = size.rows;
    final s = ScreenBuffer(cols, rows);
    s.clear(Palette.editorBg);
    final full = Rect(0, 0, cols, rows);
    final (aboveStatus, statusRect) = full.splitBottom(1);
    final (content, hintRect) = rows >= 4
        ? aboveStatus.splitBottom(1)
        : (aboveStatus, Rect.empty);

    switch (_screenId) {
      case _Screen.login:
        _renderLogin(s, content);
        _renderHints(s, hintRect, const [
          ('↑↓', 'move'),
          ('Enter', 'select'),
          ('Space', 'toggle'),
          ('^Q', 'quit'),
        ]);
      case _Screen.nodes:
        _renderNodes(s, content);
        _renderHints(s, hintRect, const [
          ('↑↓', 'move'),
          ('Enter', 'open'),
          ('r', 'refresh'),
          ('L', 'logout'),
          ('^Q', 'quit'),
        ]);
      case _Screen.nodeDetail:
        _renderNodeDetail(s, content);
        _renderHints(s, hintRect, const [
          ('Enter', 'resume'),
          ('n', 'new'),
          ('p', 'peek'),
          ('d', 'detach'),
          ('k', 'kill'),
          ('r', 'refresh'),
          ('Esc', 'back'),
        ]);
    }

    _renderStatus(s, statusRect);

    final confirm = _confirm;
    if (confirm != null) {
      InputDialog.render(
        s,
        full,
        title: confirm.title,
        value: '',
        hint: confirm.hint,
      );
    }

    _terminal.present(s);
    _screen = s;
  }

  void _renderLogin(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return;
    final x = area.left + 2;
    final w = (area.width - 4).clamp(10, 90);
    var y = area.top + 1;
    s.drawText(
      x,
      y,
      '◆  OmnyShell Dashboard',
      Palette.editorBg.copyWith(fg: const Color.indexed(81), bold: true),
    );
    y += 2;

    // Error banner (message + hint) — mirrors the web login's inline error.
    if (_messageIsError && _message != null && y + 1 < area.bottom) {
      s.fillRect(x, y, w, 1, ' ', Palette.statusError);
      s.drawText(x + 1, y, _message!, Palette.statusError, maxWidth: w - 2);
      y++;
      final hint = _messageHint;
      if (hint != null) {
        s.drawText(
          x + 1,
          y,
          hint,
          Palette.editorBg.copyWith(fg: const Color.indexed(203)),
          maxWidth: w - 2,
        );
        y++;
      }
      y++;
    }

    if (_auth.logins.isNotEmpty && y < area.bottom) {
      s.drawText(x, y, 'SAVED SESSIONS', _heading);
      y++;
      for (var i = 0; i < _auth.logins.length && y < area.bottom; i++) {
        final l = _auth.logins[i];
        final focused = _loginFocus == i;
        final style = focused ? Palette.treeSelectedActive : Palette.treeFile;
        s.fillRect(x, y, w, 1, ' ', style);
        final tag = l.isDefault ? '  (default)' : '';
        s.drawText(
          x + 1,
          y,
          '${l.principal}@${l.hubUrl}$tag',
          style,
          maxWidth: w - 2,
        );
        y++;
      }
      y++;
    }

    if (y >= area.bottom) return;
    s.drawText(x, y, 'NEW LOGIN', _heading);
    y++;
    final base = _loginFieldBase;
    y = _fieldRow(
      s,
      x,
      y,
      w,
      'Hub',
      _hub,
      focused: _loginFocus == base + 0,
      caret: true,
    );
    y = _fieldRow(
      s,
      x,
      y,
      w,
      'Principal',
      _principalInput,
      focused: _loginFocus == base + 1,
      caret: true,
    );
    y = _fieldRow(
      s,
      x,
      y,
      w,
      'Method',
      _method == LoginMethod.token ? 'token' : 'public-key (seed file)',
      focused: _loginFocus == base + 2,
    );
    final secretLabel = _method == LoginMethod.token ? 'Token' : 'Key path';
    final secretShown = _method == LoginMethod.token
        ? '•' * _secret.length
        : _secret;
    y = _fieldRow(
      s,
      x,
      y,
      w,
      secretLabel,
      secretShown,
      focused: _loginFocus == base + 3,
      caret: true,
    );
    y = _fieldRow(
      s,
      x,
      y,
      w,
      'Insecure TLS',
      _insecure ? 'yes' : 'no',
      focused: _loginFocus == base + 4,
    );

    if (y < area.bottom) {
      final focused = _loginFocus == base + 5;
      final style = focused
          ? Palette.statusBar.copyWith(bold: true)
          : Palette.tabInactive;
      s.fillRect(x, y, 12, 1, ' ', style);
      s.drawText(x + 2, y, 'Connect', style);
    }
  }

  int _fieldRow(
    ScreenBuffer s,
    int x,
    int y,
    int w,
    String label,
    String value, {
    required bool focused,
    bool caret = false,
  }) {
    final labelStyle = Palette.editorBg.copyWith(fg: const Color.indexed(245));
    final valueStyle = focused ? Palette.treeSelectedActive : Palette.treeFile;
    s.drawText(x, y, '$label:', labelStyle, maxWidth: 14);
    final vx = x + 15;
    final vw = (w - 15).clamp(1, w);
    s.fillRect(vx, y, vw, 1, ' ', valueStyle);
    final shown = caret && focused ? '$value▏' : value;
    s.drawText(vx + 1, y, shown, valueStyle, maxWidth: vw - 1);
    return y + 1;
  }

  void _renderNodes(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return;
    final (header, listRect) = area.splitTop(2);
    _bar(s, _row(header, 0), ' Nodes', Palette.statusBar.copyWith(bold: true));
    final online = _nodes.where((n) => n.online).length;
    _bar(
      s,
      _row(header, 1),
      '${_backend.connectedHub ?? '?'}  ·  '
      '${_backend.principal?.displayName ?? '?'}  ·  '
      '${_nodes.length} node(s), $online online${_loading ? '  ·  refreshing…' : ''}',
      Palette.statusBarAlt,
    );

    _nodeScroll = _ensureVisible(
      _nodeSel,
      _nodeScroll,
      listRect.height,
      _nodes.length,
    );
    if (_nodes.isEmpty) {
      s.drawText(
        listRect.left + 2,
        listRect.top,
        'No nodes visible. Press r to refresh.',
        Palette.treeFile.copyWith(fg: const Color.indexed(245)),
      );
      return;
    }
    for (var i = 0; i < listRect.height; i++) {
      final idx = _nodeScroll + i;
      if (idx >= _nodes.length) break;
      final n = _nodes[idx];
      final y = listRect.top + i;
      final selected = idx == _nodeSel;
      final style = selected ? Palette.treeSelectedActive : Palette.treeFile;
      s.fillRect(listRect.left, y, listRect.width, 1, ' ', style);
      s.setCell(
        listRect.left + 1,
        y,
        n.online ? '●' : '○',
        style.copyWith(
          fg: n.online ? const Color.indexed(114) : const Color.indexed(244),
        ),
      );
      final after = s.drawText(
        listRect.left + 3,
        y,
        '${_pad(n.id.value, 22)} ${n.platform.os}/${n.platform.arch}',
        style,
        maxWidth: listRect.width - 4,
      );
      if (n.labels.isNotEmpty && after + 2 < listRect.right) {
        final labels = n.labels.entries
            .map((e) => '${e.key}=${e.value}')
            .join(' ');
        s.drawText(
          after + 2,
          y,
          labels,
          style.copyWith(fg: const Color.indexed(109)),
          maxWidth: listRect.right - after - 2,
        );
      }
    }
  }

  void _renderNodeDetail(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return;
    final node = _currentNode;
    if (node == null) return;
    final infoLines = _nodeInfoLines(node);
    final infoH = (infoLines.length + 1).clamp(
      0,
      (area.height - 2).clamp(0, area.height),
    );
    final (infoRect, rest) = area.splitTop(infoH);

    _bar(
      s,
      _row(infoRect, 0),
      ' Node ${node.id.value}${_loading ? '   (refreshing…)' : ''}',
      Palette.statusBar.copyWith(bold: true),
    );
    final labelStyle = Palette.panelBg.copyWith(fg: const Color.indexed(245));
    final valueStyle = Palette.panelBg.copyWith(fg: const Color.indexed(252));
    for (var i = 0; i < infoLines.length; i++) {
      final y = infoRect.top + 1 + i;
      if (y >= infoRect.bottom) break;
      final (label, value) = infoLines[i];
      s.fillRect(infoRect.left, y, infoRect.width, 1, ' ', Palette.panelBg);
      s.drawText(infoRect.left + 2, y, label, labelStyle, maxWidth: 14);
      s.drawText(
        infoRect.left + 16,
        y,
        value,
        valueStyle,
        maxWidth: (infoRect.width - 18).clamp(1, infoRect.width),
      );
    }

    if (rest.isEmpty) return;
    final (headerRow, listRect) = rest.splitTop(1);
    _bar(
      s,
      headerRow,
      ' ${_pad('ID', 10)} ${_pad('STATUS', 9)} ${_pad('AGE', 6)} '
      '${_pad('EXPIRES', 8)} ${_pad('COMMAND', 16)} PATH',
      Palette.tabInactive.copyWith(bold: true),
    );

    _sessionScroll = _ensureVisible(
      _sessionSel,
      _sessionScroll,
      listRect.height,
      _sessions.length,
    );
    if (_sessions.isEmpty) {
      s.drawText(
        listRect.left + 1,
        listRect.top,
        'No sessions on this node. Press n for a new shell, r to refresh.',
        Palette.treeFile.copyWith(fg: const Color.indexed(245)),
      );
      return;
    }
    for (var i = 0; i < listRect.height; i++) {
      final idx = _sessionScroll + i;
      if (idx >= _sessions.length) break;
      _drawSessionRow(
        s,
        listRect,
        listRect.top + i,
        _sessions[idx],
        selected: idx == _sessionSel,
      );
    }
  }

  /// Draws one session row with per-column colours: the state (green when
  /// attached, amber when detached/parked), a running command in green, and an
  /// expired lease in red — plus a `▸` marker on the last-interacted session.
  void _drawSessionRow(
    ScreenBuffer s,
    Rect listRect,
    int y,
    DetachedSessionInfo ses, {
    required bool selected,
  }) {
    final now = _now();
    final base = selected ? Palette.treeSelectedActive : Palette.treeFile;
    final muted = base.copyWith(fg: Color.indexed(selected ? 250 : 245));
    s.fillRect(listRect.left, y, listRect.width, 1, ' ', base);
    final right = listRect.right - 1;

    if (ses.shortId == _lastSessionRef) {
      s.setCell(
        listRect.left + 1,
        y,
        '▸',
        base.copyWith(fg: const Color.indexed(81)),
      );
    }

    final attached = ses.state == SessionState.attached;
    final hasCmd = (ses.currentCommand ?? '').isNotEmpty;
    final expired = ses.expiresAt != null && ses.expiresAt!.isBefore(now);
    final age = _compactDuration(
      now.difference(ses.detachedAt ?? ses.createdAt),
    );
    final expires = ses.expiresAt == null
        ? 'never'
        : (expired
              ? 'expired'
              : _compactDuration(ses.expiresAt!.difference(now)));
    final command = _truncateEnd(ses.currentCommand ?? '-', 16);
    final path = _truncateStart(ses.currentCwd ?? '-', 30);

    var cx = listRect.left + 2;
    cx = _seg(s, cx, y, right, '${_pad(ses.shortId, 10)} ', base);
    cx = _seg(
      s,
      cx,
      y,
      right,
      '${_pad(ses.state.name, 9)} ',
      base.copyWith(
        fg: attached ? const Color.indexed(114) : const Color.indexed(179),
      ),
    );
    cx = _seg(s, cx, y, right, '${_pad(age, 6)} ', muted);
    cx = _seg(
      s,
      cx,
      y,
      right,
      '${_pad(expires, 8)} ',
      expired ? base.copyWith(fg: const Color.indexed(203)) : muted,
    );
    cx = _seg(
      s,
      cx,
      y,
      right,
      '${_pad(command, 16)} ',
      hasCmd ? base.copyWith(fg: const Color.indexed(114)) : muted,
    );
    _seg(s, cx, y, right, path, muted);
  }

  /// Draws [text] at (`x`,`y`) clipped to the [right] edge; returns the next x.
  int _seg(ScreenBuffer s, int x, int y, int right, String text, Style style) {
    if (x >= right) return x;
    return s.drawText(x, y, text, style, maxWidth: right - x);
  }

  List<(String, String)> _nodeInfoLines(NodeDescriptor node) {
    final caps = node.capabilities;
    return [
      ('Name', node.displayName.isEmpty ? '—' : node.displayName),
      ('Status', node.online ? 'online' : 'offline'),
      ('Platform', '${node.platform.os}/${node.platform.arch}'),
      ('Hostname', node.platform.hostname),
      ('Agent', node.platform.agentVersion),
      if (node.uid != null) ('UID', node.uid!.value),
      if (node.labels.isNotEmpty)
        (
          'Labels',
          node.labels.entries.map((e) => '${e.key}=${e.value}').join(' '),
        ),
      if (caps != null) ('Shells', caps.shells.join(', ')),
      if (caps != null) ('Features', caps.features.join(', ')),
    ];
  }

  void _renderStatus(ScreenBuffer s, Rect r) {
    if (r.isEmpty) return;
    if (_message != null) {
      final hint = _messageHint;
      final text = hint == null ? _message! : '${_message!}  ·  $hint';
      _bar(
        s,
        r,
        text,
        _messageIsError ? Palette.statusError : Palette.statusMessage,
      );
      return;
    }
    final ctx = switch (_screenId) {
      _Screen.login =>
        'Not connected — enter credentials or pick a saved session',
      _Screen.nodes =>
        '${_backend.principal?.displayName ?? '?'} @ ${_backend.connectedHub ?? '?'}',
      _Screen.nodeDetail =>
        '${_currentNode?.id.value ?? '?'}  ·  ${_sessions.length} session(s)',
    };
    _bar(s, r, ctx, Palette.statusBar);
  }

  void _renderHints(ScreenBuffer s, Rect r, List<(String, String)> hints) {
    if (r.isEmpty) return;
    s.fillRect(r.left, r.top, r.width, 1, ' ', Palette.hintBar);
    var x = r.left + 1;
    for (final (key, label) in hints) {
      if (x >= r.right) break;
      x = s.drawText(x, r.top, key, Palette.hintKey);
      x = s.drawText(x + 1, r.top, label, Palette.hintBar) + 2;
    }
  }

  // ---- Small helpers -------------------------------------------------------

  Style get _heading =>
      Palette.editorBg.copyWith(fg: const Color.indexed(109), bold: true);

  Rect _row(Rect r, int i) => Rect(r.left, r.top + i, r.width, 1);

  void _bar(ScreenBuffer s, Rect r, String text, Style style) {
    if (r.isEmpty) return;
    s.fillRect(r.left, r.top, r.width, 1, ' ', style);
    s.drawText(r.left + 1, r.top, text, style, maxWidth: r.width - 1);
  }

  int _ensureVisible(int sel, int scroll, int height, int count) {
    if (height <= 0 || count <= 0) return 0;
    if (sel < scroll) scroll = sel;
    if (sel >= scroll + height) scroll = sel - height + 1;
    return scroll < 0 ? 0 : scroll;
  }

  int _maxIndex(int count) => count <= 0 ? 0 : count - 1;

  void _setBusy(String message) {
    _message = message;
    _messageHint = null;
    _messageIsError = false;
    if (!_done.isCompleted) _render();
  }

  void _setMessage(String message, {bool isError = false, String? hint}) {
    _message = message;
    _messageHint = hint;
    _messageIsError = isError;
  }

  /// Turns an exception into a friendly message + recovery hint and shows it,
  /// mirroring the web client's error taxonomy. When the failure dropped the Hub
  /// connection, routes back to the login screen instead.
  void _setError(String action, Object error) {
    if (_screenId != _Screen.login && !_backend.isConnected) {
      _screenId = _Screen.login;
      _setMessage(
        'Connection to the Hub was lost.',
        isError: true,
        hint: 'Reconnect to continue.',
      );
      return;
    }
    final (message, hint) = _friendlyError(error);
    _setMessage('$action: $message', isError: true, hint: hint);
  }

  /// Classifies [error] into a user-facing message and a recovery hint.
  (String, String?) _friendlyError(Object error) {
    final raw = error.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('auth') ||
        lower.contains('unauthor') ||
        lower.contains('forbidden') ||
        lower.contains('rejected')) {
      return (
        'authentication failed',
        'Check the principal and token (or key), then try again.',
      );
    }
    if (lower.contains('certificate') ||
        lower.contains('handshake') ||
        lower.contains('tls') ||
        lower.contains('ssl')) {
      return (
        'TLS verification failed',
        'Trust the Hub CA with --ca, or enable Insecure TLS for a dev hub.',
      );
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return ('the Hub did not respond in time', 'Check the Hub is reachable.');
    }
    if (lower.contains('socket') ||
        lower.contains('refused') ||
        lower.contains('connection') ||
        lower.contains('network') ||
        lower.contains('failed host lookup')) {
      return (
        'cannot reach the Hub',
        'Verify the Hub address and that its port is open.',
      );
    }
    if (lower.contains('not found')) {
      return (_short(raw), null);
    }
    return (_short(raw), null);
  }

  Future<AuthSnapshot> _safeAuthSnapshot() async {
    try {
      return await _backend.authSnapshot();
    } on Object {
      return const AuthSnapshot();
    }
  }

  String _short(Object e) {
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 119)}…' : s;
  }

  static String _pad(String s, int width) =>
      s.length >= width ? s : s.padRight(width);

  static String _compactDuration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  static String _truncateEnd(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n - 1)}…';

  static String _truncateStart(String s, int n) =>
      s.length <= n ? s : '…${s.substring(s.length - (n - 1))}';
}
