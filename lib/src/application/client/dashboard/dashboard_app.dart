import 'dart:async';
import 'dart:convert' show LineSplitter;

import '../../../domain/entities/node_descriptor.dart';
import '../../../domain/entities/detached_session_info.dart';
import '../../../domain/entities/session.dart' show SessionState;
import '../../../domain/entities/tunnel_info.dart';
import '../../ai/agent_mode.dart';
import '../../ai/ai_config.dart' show AiProviderKind;
import '../../ai/ai_config_io.dart' show AiConfigDescription;
import '../../../shared/utils/progress_bar.dart' show formatFileDiff;
import '../../../protocol/control_message.dart' show DriveCredentialEntry;
import '../drive/drive_manager.dart' show SyncOutcome, DriveChanges;
import '../drive/mount_store.dart' show MountRecord;
import '../ide/tui/geometry.dart';
import '../ide/tui/key.dart';
import '../ide/tui/key_decoder.dart';
import '../ide/tui/screen_buffer.dart';
import '../ide/tui/style.dart';
import '../ide/tui/terminal_driver.dart';
import '../ide/widgets/input_dialog.dart';
import '../ide/widgets/palette.dart';
import 'dashboard_backend.dart';

/// Which screen the dashboard is currently showing. `nodes`, `tunnels`, `drive`
/// and `ai` are the four top-level tabs; `nodeDetail`/`driveDetail` are
/// sub-screens reached from their tab.
enum _Screen {
  login,
  nodes,
  nodeDetail,
  nodeCredentials,
  tunnels,
  drive,
  driveDetail,
  ai,
}

/// A pending yes/no confirmation (the terminate-session prompt). While active it
/// captures input: `y`/Enter runs [onYes], `n` dismisses it.
class _Confirm {
  _Confirm({required this.title, required this.hint, required this.onYes});

  final String title;
  final String hint;
  final Future<void> Function() onYes;
}

/// The kind of a [_Field] in a modal [_Form].
enum _FieldKind { text, secret, toggle, choice }

/// One editable field in a modal [_Form].
class _Field {
  _Field.text(this.label, {this.value = ''})
    : kind = _FieldKind.text,
      choices = const [];
  _Field.secret(this.label)
    : kind = _FieldKind.secret,
      value = '',
      choices = const [];
  _Field.toggle(this.label, {bool on = false})
    : kind = _FieldKind.toggle,
      value = on ? 'on' : 'off',
      choices = const [];
  _Field.choice(this.label, this.choices, {String? value})
    : kind = _FieldKind.choice,
      value = value ?? (choices.isEmpty ? '' : choices.first);

  final String label;
  final _FieldKind kind;
  final List<String> choices;
  String value;

  bool get isOn => value == 'on';
}

/// A modal multi-field input form (tunnel open, drive mount, AI config), modelled
/// on the login screen's field-focus pattern. While active it captures input;
/// Enter on the Submit row runs [onSubmit] (returning `true` closes the form,
/// `false` keeps it open for a validation retry), Esc cancels.
class _Form {
  _Form({
    required this.title,
    required this.fields,
    required this.onSubmit,
    this.hint,
  });

  final String title;
  final List<_Field> fields;
  final String? hint;
  final Future<bool> Function(List<_Field> fields) onSubmit;

  /// Focus index; `fields.length` is the Submit row.
  int focus = 0;
}

/// A read-only scrollable text overlay (a pager) used for file diffs and the AI
/// test report. Esc closes it.
class _Pager {
  _Pager(this.title, this.lines);
  final String title;
  final List<String> lines;
  int scroll = 0;
}

/// A full-screen TUI over the OmnyShell CLI: log in to a Hub, then work across
/// four top-level tabs — Nodes (browse a node's info and sessions, and
/// resume / peek / detach / terminate them), Tunnels (open / list / close),
/// Drive (mount / sync / diff / resolve / unmount / remount) and AI (view / edit
/// config, validate models) — without typing individual commands. Tab / Shift-Tab
/// (or the number keys) switch tabs.
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
  _Form? _form;
  _Pager? _pager;

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

  // The caller's own git credentials on [_currentNode] (node-credentials screen).
  List<DriveCredentialEntry> _credentials = const [];
  int _credSel = 0;
  int _credScroll = 0;
  int _sessionScroll = 0;

  // Tunnels screen state.
  List<TunnelInfo> _tunnels = const [];
  int _tunnelSel = 0;
  int _tunnelScroll = 0;

  // Drive screen state.
  List<MountRecord> _mounts = const [];
  int _mountSel = 0;
  int _mountScroll = 0;
  MountRecord? _currentMount;
  DriveChanges? _mountChanges;

  // AI screen state.
  AiConfigDescription? _aiDesc;

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
          // Never let an unexpected error from a key handler crash or freeze the
          // TUI: surface it in the status bar and keep the loop alive.
          try {
            await _handleKey(key);
          } on Object catch (e) {
            _setError('Unexpected error', e);
          }
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
    final pager = _pager;
    if (pager != null) {
      _handlePagerKey(key, pager);
      return;
    }
    final form = _form;
    if (form != null) {
      await _handleFormKey(key, form);
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
    // Tab / Shift-Tab (and number keys) switch between the top-level tabs from
    // any tab screen; the detail sub-screens fall through to Esc-to-go-back.
    if (_isTabScreen(_screenId)) {
      if (key.type == KeyType.tab) {
        await _cycleTab(1);
        return;
      }
      if (key.type == KeyType.backTab) {
        await _cycleTab(-1);
        return;
      }
      if (key.type == KeyType.char) {
        const digits = {'1': 0, '2': 1, '3': 2, '4': 3};
        final i = digits[key.text];
        if (i != null) {
          await _switchTab(_tabs[i]);
          return;
        }
      }
    }
    switch (_screenId) {
      case _Screen.login:
        await _handleLoginKey(key);
      case _Screen.nodes:
        await _handleNodesKey(key);
      case _Screen.nodeDetail:
        await _handleNodeDetailKey(key);
      case _Screen.nodeCredentials:
        await _handleNodeCredentialsKey(key);
      case _Screen.tunnels:
        await _handleTunnelsKey(key);
      case _Screen.drive:
        await _handleDriveKey(key);
      case _Screen.driveDetail:
        await _handleDriveDetailKey(key);
      case _Screen.ai:
        await _handleAiKey(key);
    }
  }

  // ---- Tabs ----------------------------------------------------------------

  /// The four top-level tabs, in bar order.
  static const _tabs = [
    _Screen.nodes,
    _Screen.tunnels,
    _Screen.drive,
    _Screen.ai,
  ];

  /// The tab-bar labels, aligned with [_tabs].
  static const _tabLabels = ['Nodes', 'Tunnels', 'Drive', 'AI'];

  /// Whether [s] is a top-level tab screen (so Tab/number keys switch tabs).
  bool _isTabScreen(_Screen s) => _tabs.contains(s);

  /// The tab currently active (detail sub-screens map to their parent tab).
  _Screen get _activeTab => switch (_screenId) {
    _Screen.nodeDetail => _Screen.nodes,
    _Screen.nodeCredentials => _Screen.nodes,
    _Screen.driveDetail => _Screen.drive,
    final s => s,
  };

  Future<void> _cycleTab(int delta) async {
    final cur = _tabs.indexOf(_activeTab);
    final next = (cur + delta + _tabs.length) % _tabs.length;
    await _switchTab(_tabs[next]);
  }

  /// Switches to top-level [tab] and (re)loads its data.
  Future<void> _switchTab(_Screen tab) async {
    if (_screenId == tab) return;
    _screenId = tab;
    switch (tab) {
      case _Screen.nodes:
        await _reloadNodes(busy: true);
      case _Screen.tunnels:
        await _reloadTunnels(busy: true);
      case _Screen.drive:
        await _reloadMounts(busy: true);
      case _Screen.ai:
        await _reloadAi(busy: true);
      default:
        break;
    }
  }

  Future<void> _handleConfirmKey(KeyEvent key, _Confirm confirm) async {
    final yes =
        key.type == KeyType.enter ||
        (key.type == KeyType.char && (key.text == 'y' || key.text == 'Y'));
    final no = key.type == KeyType.char && (key.text == 'n' || key.text == 'N');
    if (yes) {
      _confirm = null;
      await confirm.onYes();
    } else if (no) {
      _confirm = null;
    }
  }

  // ---- Modal form ----------------------------------------------------------

  Future<void> _handleFormKey(KeyEvent key, _Form form) async {
    final n = form.fields.length + 1; // + Submit row
    final field = form.focus < form.fields.length
        ? form.fields[form.focus]
        : null;
    switch (key.type) {
      case KeyType.escape:
        _form = null;
      case KeyType.up:
      case KeyType.backTab:
        form.focus = (form.focus - 1 + n) % n;
      case KeyType.down:
      case KeyType.tab:
        form.focus = (form.focus + 1) % n;
      case KeyType.enter:
        if (form.focus == form.fields.length) {
          if (await form.onSubmit(form.fields)) _form = null;
        } else {
          form.focus = (form.focus + 1) % n;
        }
      case KeyType.left:
      case KeyType.right:
        if (field != null) {
          _formCycle(field, key.type == KeyType.right ? 1 : -1);
        }
      case KeyType.backspace:
        if (field != null &&
            (field.kind == _FieldKind.text ||
                field.kind == _FieldKind.secret) &&
            field.value.isNotEmpty) {
          field.value = field.value.substring(0, field.value.length - 1);
        }
      case KeyType.char:
        if (field == null || key.text.isEmpty) break;
        if (field.kind == _FieldKind.toggle && key.text == ' ') {
          field.value = field.isOn ? 'off' : 'on';
        } else if (field.kind == _FieldKind.choice && key.text == ' ') {
          _formCycle(field, 1);
        } else if (field.kind == _FieldKind.text ||
            field.kind == _FieldKind.secret) {
          field.value += key.text;
        }
      default:
        break;
    }
  }

  void _formCycle(_Field field, int delta) {
    if (field.kind == _FieldKind.toggle) {
      field.value = field.isOn ? 'off' : 'on';
    } else if (field.kind == _FieldKind.choice && field.choices.isNotEmpty) {
      final i = field.choices.indexOf(field.value);
      final next = (i + delta + field.choices.length) % field.choices.length;
      field.value = field.choices[next];
    }
  }

  // ---- Pager ---------------------------------------------------------------

  void _handlePagerKey(KeyEvent key, _Pager pager) {
    final page = (_terminal.size.rows - 4).clamp(1, 1 << 20);
    switch (key.type) {
      case KeyType.escape:
      case KeyType.enter:
        _pager = null;
      case KeyType.up:
        pager.scroll = (pager.scroll - 1).clamp(
          0,
          _maxIndex(pager.lines.length),
        );
      case KeyType.down:
        pager.scroll = (pager.scroll + 1).clamp(
          0,
          _maxIndex(pager.lines.length),
        );
      case KeyType.pageUp:
        pager.scroll = (pager.scroll - page).clamp(
          0,
          _maxIndex(pager.lines.length),
        );
      case KeyType.pageDown:
        pager.scroll = (pager.scroll + page).clamp(
          0,
          _maxIndex(pager.lines.length),
        );
      case KeyType.home:
        pager.scroll = 0;
      case KeyType.end:
        pager.scroll = _maxIndex(pager.lines.length);
      case KeyType.char:
        if (key.text == 'q') _pager = null;
      default:
        break;
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
    // Drop the previously opened node's sessions so the list starts empty while
    // this node's sessions load, rather than briefly showing stale rows.
    _sessions = const [];
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
          case 'c':
            await _openNodeCredentials();
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
      hint: '${s.shortId} on ${node.id.value}  ·  y = terminate · n = cancel',
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

  // ---- Node credentials screen ---------------------------------------------

  /// Opens the caller's git-credential view for the current node.
  Future<void> _openNodeCredentials() async {
    if (_currentNode == null) return;
    _screenId = _Screen.nodeCredentials;
    _credSel = 0;
    _credScroll = 0;
    _credentials = const [];
    _refreshCredentials();
  }

  /// Loads the credentials in the background so the input loop stays responsive
  /// even if the node is slow or unreachable (the RPC is time-boxed); re-renders
  /// when it settles.
  void _refreshCredentials() {
    _setBusy('Loading credentials…');
    unawaited(
      _reloadCredentials().whenComplete(() {
        if (!_done.isCompleted) _render();
      }),
    );
  }

  Future<void> _reloadCredentials() async {
    final node = _currentNode;
    if (node == null) return;
    _loading = true;
    try {
      _credentials = await _backend.listGitCredentials(node.id.value);
      if (_credSel > _maxIndex(_credentials.length)) {
        _credSel = _maxIndex(_credentials.length);
      }
      // Replace the "Loading credentials…" status with a summary. The background
      // load finishes without a keypress, which is what would otherwise clear a
      // transient message — so an empty result would look stuck on "Loading…".
      final n = _credentials.length;
      _setMessage(
        n == 0
            ? 'No git credentials for you on ${node.id.value}.'
            : '$n git credential${n == 1 ? '' : 's'} on ${node.id.value}.',
      );
    } on Object catch (e) {
      if (_credentials.isEmpty) {
        _setError('Failed to list credentials', e);
      } else {
        _setError('Showing last results — refresh failed', e);
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> _handleNodeCredentialsKey(KeyEvent key) async {
    switch (key.type) {
      case KeyType.up:
        _credSel = (_credSel - 1).clamp(0, _maxIndex(_credentials.length));
      case KeyType.down:
        _credSel = (_credSel + 1).clamp(0, _maxIndex(_credentials.length));
      case KeyType.pageUp:
        _credSel = (_credSel - 10).clamp(0, _maxIndex(_credentials.length));
      case KeyType.pageDown:
        _credSel = (_credSel + 10).clamp(0, _maxIndex(_credentials.length));
      case KeyType.home:
        _credSel = 0;
      case KeyType.end:
        _credSel = _maxIndex(_credentials.length);
      case KeyType.escape:
      case KeyType.left:
        _screenId = _Screen.nodeDetail;
      case KeyType.char:
        switch (key.text) {
          case 'a':
          case 'n':
            _openCredentialForm();
          case 'x':
          case 'd':
            _confirmRemoveCredential();
          case 'r':
            _refreshCredentials();
        }
      default:
        break;
    }
  }

  DriveCredentialEntry? get _selectedCredential {
    if (_credentials.isEmpty) return null;
    return _credentials[_credSel.clamp(0, _maxIndex(_credentials.length))];
  }

  void _openCredentialForm() {
    final node = _currentNode;
    if (node == null) return;
    _form = _Form(
      title: 'Add git credential on ${node.id.value}',
      hint: 'Tab move · Space toggle · Enter submit · Esc cancel',
      fields: [
        _Field.text('Host (e.g. github.com)'),
        _Field.toggle('Use username + password'),
        _Field.secret('PAT / password'),
        _Field.text('Username (for user/pass, or PAT user)'),
      ],
      onSubmit: (f) async {
        final host = f[0].value.trim();
        final userpass = f[1].isOn;
        final secret = f[2].value;
        final user = f[3].value.trim();
        if (host.isEmpty) {
          _setMessage('Host is required.', isError: true);
          return false;
        }
        if (secret.isEmpty) {
          _setMessage('A PAT or password is required.', isError: true);
          return false;
        }
        if (userpass && user.isEmpty) {
          _setMessage('Username is required for user/password.', isError: true);
          return false;
        }
        _setBusy('Storing credential…');
        try {
          final r = await _backend.addGitCredential(
            node.id.value,
            host: host,
            pat: userpass ? null : secret,
            username: user.isEmpty ? null : user,
            password: userpass ? secret : null,
          );
          _setMessage(r.message, isError: !r.ok);
        } on Object catch (e) {
          _setError('Add credential failed', e);
        }
        await _reloadCredentials();
        return true;
      },
    );
  }

  void _confirmRemoveCredential() {
    final entry = _selectedCredential;
    final node = _currentNode;
    if (entry == null || node == null) return;
    _confirm = _Confirm(
      title: 'Remove credential?',
      hint: '${entry.host} on ${node.id.value}  ·  y = remove · n = cancel',
      onYes: () async {
        _setBusy('Removing credential…');
        try {
          final r = await _backend.removeGitCredential(
            node.id.value,
            host: entry.host,
          );
          _setMessage(r.message, isError: !r.ok);
        } on Object catch (e) {
          _setError('Remove credential failed', e);
        }
        await _reloadCredentials();
      },
    );
  }

  // ---- Tunnels screen ------------------------------------------------------

  Future<void> _handleTunnelsKey(KeyEvent key) async {
    switch (key.type) {
      case KeyType.up:
        _tunnelSel = (_tunnelSel - 1).clamp(0, _maxIndex(_tunnels.length));
      case KeyType.down:
        _tunnelSel = (_tunnelSel + 1).clamp(0, _maxIndex(_tunnels.length));
      case KeyType.pageUp:
        _tunnelSel = (_tunnelSel - 10).clamp(0, _maxIndex(_tunnels.length));
      case KeyType.pageDown:
        _tunnelSel = (_tunnelSel + 10).clamp(0, _maxIndex(_tunnels.length));
      case KeyType.home:
        _tunnelSel = 0;
      case KeyType.end:
        _tunnelSel = _maxIndex(_tunnels.length);
      case KeyType.enter:
        _openTunnelForm();
      case KeyType.char:
        switch (key.text) {
          case 'o':
            _openTunnelForm();
          case 'c':
          case 'k':
            _confirmCloseTunnel();
          case 'r':
            await _reloadTunnels(busy: true);
        }
      default:
        break;
    }
  }

  TunnelInfo? get _selectedTunnel {
    if (_tunnels.isEmpty) return null;
    return _tunnels[_tunnelSel.clamp(0, _maxIndex(_tunnels.length))];
  }

  Future<void> _reloadTunnels({bool busy = false}) async {
    if (busy) _setBusy('Loading tunnels…');
    _loading = true;
    try {
      _tunnels = await _backend.listTunnels();
      if (_tunnelSel > _maxIndex(_tunnels.length)) {
        _tunnelSel = _maxIndex(_tunnels.length);
      }
    } on Object catch (e) {
      if (_tunnels.isEmpty) {
        _setError('Failed to list tunnels', e);
      } else {
        _setError('Showing last results — refresh failed', e);
      }
    } finally {
      _loading = false;
    }
  }

  void _openTunnelForm() {
    _form = _Form(
      title: 'Open tunnel',
      hint: 'Tab move · Space toggle · Enter submit · Esc cancel',
      fields: [
        _Field.toggle('Local (this machine)'),
        _Field.text('Node'),
        _Field.text('Target port'),
        _Field.text('Public port (optional)'),
        _Field.toggle('Secure (TLS)'),
      ],
      onSubmit: (f) async {
        final local = f[0].isOn;
        final node = f[1].value.trim();
        final port = int.tryParse(f[2].value.trim());
        final ppRaw = f[3].value.trim();
        final secure = f[4].isOn;
        if (port == null || port < 1 || port > 65535) {
          _setMessage('Invalid target port (1-65535).', isError: true);
          return false;
        }
        if (!local && node.isEmpty) {
          _setMessage('Node is required (or enable Local).', isError: true);
          return false;
        }
        int? publicPort;
        if (ppRaw.isNotEmpty) {
          publicPort = int.tryParse(ppRaw);
          if (publicPort == null) {
            _setMessage('Invalid public port.', isError: true);
            return false;
          }
        }
        _setBusy('Opening tunnel…');
        try {
          final r = await _backend.openTunnel(
            nodeId: local ? '' : node,
            targetPort: port,
            publicPort: publicPort,
            local: local,
            secure: secure,
          );
          _setMessage(r.message, isError: !r.ok);
        } on Object catch (e) {
          _setError('Open tunnel failed', e);
        }
        await _reloadTunnels();
        return true;
      },
    );
  }

  void _confirmCloseTunnel() {
    final t = _selectedTunnel;
    if (t == null) return;
    _confirm = _Confirm(
      title: 'Close tunnel?',
      hint: '${t.shortId}  ·  y = close · n = cancel',
      onYes: () async {
        _setBusy('Closing ${t.shortId}…');
        try {
          final r = await _backend.closeTunnel(t.shortId);
          _setMessage(r.message, isError: !r.ok);
        } on Object catch (e) {
          _setError('Close failed', e);
        }
        await _reloadTunnels();
      },
    );
  }

  // ---- Drive screen --------------------------------------------------------

  Future<void> _handleDriveKey(KeyEvent key) async {
    switch (key.type) {
      case KeyType.up:
        _mountSel = (_mountSel - 1).clamp(0, _maxIndex(_mounts.length));
      case KeyType.down:
        _mountSel = (_mountSel + 1).clamp(0, _maxIndex(_mounts.length));
      case KeyType.pageUp:
        _mountSel = (_mountSel - 10).clamp(0, _maxIndex(_mounts.length));
      case KeyType.pageDown:
        _mountSel = (_mountSel + 10).clamp(0, _maxIndex(_mounts.length));
      case KeyType.home:
        _mountSel = 0;
      case KeyType.end:
        _mountSel = _maxIndex(_mounts.length);
      case KeyType.enter:
      case KeyType.right:
        await _openMount();
      case KeyType.char:
        switch (key.text) {
          case 'm':
            _openMountForm();
          case 's':
            await _syncSelectedMount();
          case 'u':
            _confirmUnmount();
          case 'R':
            await _remountSelected();
          case 'r':
            await _reloadMounts(busy: true);
        }
      default:
        break;
    }
  }

  MountRecord? get _selectedMount {
    if (_mounts.isEmpty) return null;
    return _mounts[_mountSel.clamp(0, _maxIndex(_mounts.length))];
  }

  Future<void> _reloadMounts({bool busy = false}) async {
    if (busy) _setBusy('Loading mounts…');
    _loading = true;
    try {
      _mounts = await _backend.listMounts();
      if (_mountSel > _maxIndex(_mounts.length)) {
        _mountSel = _maxIndex(_mounts.length);
      }
    } on Object catch (e) {
      if (_mounts.isEmpty) {
        _setError('Failed to list mounts', e);
      } else {
        _setError('Showing last results — refresh failed', e);
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> _openMount() async {
    final m = _selectedMount;
    if (m == null) return;
    _currentMount = m;
    _mountChanges = null;
    _screenId = _Screen.driveDetail;
    await _reloadMountChanges(busy: true);
  }

  Future<void> _reloadMountChanges({bool busy = false}) async {
    final m = _currentMount;
    if (m == null) return;
    if (busy) _setBusy('Checking ${m.id}…');
    _loading = true;
    try {
      _mountChanges = await _backend.mountConflicts(m.id);
    } on Object catch (e) {
      _setError('Failed to inspect mount', e);
    } finally {
      _loading = false;
    }
  }

  void _openMountForm() {
    _form = _Form(
      title: 'Mount',
      hint: 'Tab move · Space toggle · Enter submit · Esc cancel',
      fields: [
        _Field.toggle('Git source'),
        _Field.text('Local dir / git URL'),
        _Field.text('Target (node:/remote/path)'),
        _Field.text('Name (optional)'),
        _Field.text('Branch (git, optional)'),
        _Field.toggle('Read-write'),
      ],
      onSubmit: (f) async {
        final git = f[0].isOn;
        final source = f[1].value.trim();
        final target = f[2].value.trim();
        final name = f[3].value.trim();
        final branch = f[4].value.trim();
        final rw = f[5].isOn;
        if (source.isEmpty || target.isEmpty) {
          _setMessage('Source and target are required.', isError: true);
          return false;
        }
        _setBusy('Mounting…');
        try {
          final rec = git
              ? await _backend.mountGit(
                  url: source,
                  target: target,
                  name: name.isEmpty ? null : name,
                  branch: branch.isEmpty ? null : branch,
                  rw: rw,
                )
              : await _backend.mountDirectory(
                  localDir: source,
                  target: target,
                  name: name.isEmpty ? null : name,
                  rw: rw,
                );
          _setMessage('Mounted ${rec.id}.');
        } on Object catch (e) {
          _setError('Mount failed', e);
        }
        await _reloadMounts();
        return true;
      },
    );
  }

  Future<void> _syncSelectedMount() async {
    final m = _selectedMount;
    if (m == null) return;
    await _syncMount(m.id);
    await _reloadMounts();
  }

  Future<void> _syncMount(String id) async {
    _setBusy('Syncing $id…');
    try {
      final o = await _backend.syncMount(id);
      _setMessage(_syncSummary(o), isError: o.isConflict);
    } on Object catch (e) {
      _setError('Sync failed', e);
    }
  }

  void _confirmUnmount() {
    final m = _selectedMount;
    if (m == null) return;
    _confirm = _Confirm(
      title: 'Unmount?',
      hint: '${m.id}  ·  y = unmount (keeps node files) · n = cancel',
      onYes: () async {
        _setBusy('Unmounting ${m.id}…');
        try {
          final r = await _backend.unmount(m.id);
          _setMessage(r.message, isError: !r.ok);
        } on Object catch (e) {
          _setError('Unmount failed', e);
        }
        await _reloadMounts();
      },
    );
  }

  Future<void> _remountSelected() async {
    final m = _selectedMount;
    if (m == null) return;
    _setBusy('Remounting ${m.id}…');
    try {
      final rec = await _backend.remount(m.id);
      _setMessage('Remounted ${rec.id}.');
    } on Object catch (e) {
      _setError('Remount failed', e);
    }
    await _reloadMounts();
  }

  // ---- Drive-detail screen -------------------------------------------------

  Future<void> _handleDriveDetailKey(KeyEvent key) async {
    switch (key.type) {
      case KeyType.escape:
      case KeyType.left:
        _screenId = _Screen.drive;
      case KeyType.char:
        switch (key.text) {
          case 's':
            await _syncCurrentMount();
          case 'w':
            await _watchCurrentMount();
          case 'x':
            _openResolveForm();
          case 'D':
            _openDiffForm();
          case 'r':
            await _reloadMountChanges(busy: true);
        }
      default:
        break;
    }
  }

  Future<void> _syncCurrentMount() async {
    final m = _currentMount;
    if (m == null) return;
    await _syncMount(m.id);
    await _reloadMountChanges();
    await _reloadMounts();
  }

  Future<void> _watchCurrentMount() async {
    final m = _currentMount;
    if (m == null) return;
    try {
      await _withTerminalReleased(() => _backend.watchMount(m.id));
      _setMessage('Stopped watching ${m.id}.');
    } on Object catch (e) {
      _setError('Watch failed', e);
    }
    await _reloadMountChanges();
    await _reloadMounts();
  }

  void _openDiffForm() {
    final m = _currentMount;
    if (m == null) return;
    _form = _Form(
      title: 'Diff file',
      hint: 'Enter submit · Esc cancel',
      fields: [_Field.text('File path (relative to mount)')],
      onSubmit: (f) async {
        final path = f[0].value.trim();
        if (path.isEmpty) {
          _setMessage('A file path is required.', isError: true);
          return false;
        }
        _setBusy('Diffing $path…');
        try {
          final d = await _backend.diffFile(m.id, path);
          _pager = _Pager(
            'diff · ${m.id} · $path',
            const LineSplitter().convert(formatFileDiff(d)),
          );
          _message = null;
        } on Object catch (e) {
          _setError('Diff failed', e);
        }
        return true;
      },
    );
  }

  void _openResolveForm() {
    final m = _currentMount;
    if (m == null) return;
    _form = _Form(
      title: 'Resolve conflict',
      hint: 'Space/←→ cycle strategy · Enter submit · Esc cancel',
      fields: [
        _Field.choice('Strategy', const [
          'accept-local',
          'accept-origin',
          'reclone',
        ]),
        _Field.text('File path (optional)'),
      ],
      onSubmit: (f) async {
        final strategy = f[0].value;
        final path = f[1].value.trim();
        if (path.isNotEmpty && strategy == 'reclone') {
          _setMessage('reclone cannot target a single file.', isError: true);
          return false;
        }
        _setBusy('Resolving…');
        try {
          if (path.isEmpty) {
            final o = await _backend.resolveMount(m.id, strategy: strategy);
            _setMessage(
              o.isConflict
                  ? 'Still conflicted: ${o.conflict!.message}'
                  : 'Resolved ($strategy).',
              isError: o.isConflict,
            );
          } else {
            final o = await _backend.resolveFile(
              m.id,
              path,
              strategy: strategy,
            );
            _setMessage(
              o.converged
                  ? 'Resolved ${o.path} ($strategy). Mount is in sync.'
                  : 'Resolved ${o.path} ($strategy). Other paths still diverge.',
            );
          }
        } on Object catch (e) {
          _setError('Resolve failed', e);
        }
        await _reloadMountChanges();
        await _reloadMounts();
        return true;
      },
    );
  }

  /// A one-line summary of a sync outcome for the message bar.
  String _syncSummary(SyncOutcome o) {
    if (o.isConflict) return 'Conflict: ${o.conflict!.message}';
    if (o.merged) {
      return 'Merged: pushed ${o.pushedPaths.length}, '
          'pulled ${o.pulledPaths.length}';
    }
    if (o.direction != null) {
      return 'Synced ${o.direction!.wireValue}: ${o.applied} change(s)';
    }
    return 'Already up to date.';
  }

  // ---- AI screen -----------------------------------------------------------

  Future<void> _handleAiKey(KeyEvent key) async {
    switch (key.type) {
      case KeyType.char:
        switch (key.text) {
          case 'e':
            _openAiForm();
          case 't':
            await _runAiTest();
          case 'r':
            await _reloadAi(busy: true);
        }
      default:
        break;
    }
  }

  Future<void> _reloadAi({bool busy = false}) async {
    if (busy) _setBusy('Loading AI config…');
    _loading = true;
    try {
      _aiDesc = await _backend.aiDescribe();
    } on Object catch (e) {
      _setError('Failed to read AI config', e);
    } finally {
      _loading = false;
    }
  }

  void _openAiForm() {
    final d = _aiDesc;
    _form = _Form(
      title: 'AI config',
      hint: 'Space/←→ cycle · Enter submit · Esc cancel · blank key = keep',
      fields: [
        _Field.choice('Provider', const [
          '(keep)',
          'anthropic',
          'openai',
          'gemini',
        ], value: d?.provider?.wireName),
        _Field.text('Model', value: d?.model ?? ''),
        _Field.text('Planner model', value: d?.plannerModel ?? ''),
        _Field.text('Executor model', value: d?.executorModel ?? ''),
        _Field.text('Explainer model', value: d?.explainerModel ?? ''),
        _Field.secret('API key'),
        _Field.choice('Mode', const [
          'standard',
          'plan',
          'auto',
        ], value: d?.mode.wireName),
        _Field.text('Language', value: d?.language ?? ''),
        _Field.text('Base URL', value: d?.baseUrl ?? ''),
        _Field.text('Max steps', value: '${d?.maxSteps ?? ''}'),
      ],
      onSubmit: (f) async {
        // Empty / "default" / "off" / "none" clears a field back to its default;
        // a non-empty value sets it. The API key is special: a blank key leaves
        // the stored key untouched (never printed, so never editable in place).
        String? clr(String v) {
          final t = v.trim();
          final low = t.toLowerCase();
          return (t.isEmpty ||
                  low == 'default' ||
                  low == 'off' ||
                  low == 'none')
              ? ''
              : t;
        }

        int? maxSteps;
        final maxRaw = f[9].value.trim();
        if (maxRaw.isNotEmpty) {
          maxSteps = int.tryParse(maxRaw);
          if (maxSteps == null || maxSteps <= 0) {
            _setMessage('Max steps must be a positive integer.', isError: true);
            return false;
          }
        }
        final providerRaw = f[0].value;
        final keyRaw = f[5].value.trim();
        _setBusy('Saving AI config…');
        try {
          await _backend.aiConfig(
            provider: providerRaw == '(keep)'
                ? null
                : AiProviderKind.tryParse(providerRaw),
            model: clr(f[1].value),
            plannerModel: clr(f[2].value),
            executorModel: clr(f[3].value),
            explainerModel: clr(f[4].value),
            apiKey: keyRaw.isEmpty ? null : keyRaw,
            mode: AgentMode.tryParse(f[6].value),
            language: clr(f[7].value),
            baseUrl: clr(f[8].value),
            maxSteps: maxSteps,
          );
          _setMessage('AI config saved.');
        } on Object catch (e) {
          _setError('Save failed', e);
        }
        await _reloadAi();
        return true;
      },
    );
  }

  Future<void> _runAiTest() async {
    _setBusy('Validating key and models…');
    try {
      final results = await _backend.aiTest();
      final lines = [
        for (final r in results)
          r.ok
              ? '  ✓ ${r.model}${r.latencyMs == null ? '' : '  (${r.latencyMs} ms)'}'
              : '  ✗ ${r.model}: ${r.error}',
      ];
      final anyFail = results.any((r) => !r.ok);
      _pager = _Pager('AI test${anyFail ? ' — FAILED' : ' — OK'}', [
        'Validated ${results.length} model(s):',
        '',
        ...lines,
      ]);
      _message = null;
    } on Object catch (e) {
      _setError('AI test failed', e);
    }
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

    // The four connected screens (and their detail sub-screens) carry a
    // top-level tab strip; login does not.
    final body = _screenId == _Screen.login
        ? content
        : _renderTabBar(s, content);

    switch (_screenId) {
      case _Screen.login:
        _renderLogin(s, body);
        _renderHints(s, hintRect, const [
          ('↑↓', 'move'),
          ('Enter', 'select'),
          ('Space', 'toggle'),
          ('^Q', 'quit'),
        ]);
      case _Screen.nodes:
        _renderNodes(s, body);
        _renderHints(s, hintRect, const [
          ('↑↓', 'move'),
          ('Enter', 'open'),
          ('r', 'refresh'),
          ('L', 'logout'),
          ('Tab', 'tab'),
          ('^Q', 'quit'),
        ]);
      case _Screen.nodeDetail:
        _renderNodeDetail(s, body);
        _renderHints(s, hintRect, const [
          ('Enter', 'resume'),
          ('n', 'new'),
          ('p', 'peek'),
          ('d', 'detach'),
          ('k', 'kill'),
          ('c', 'creds'),
          ('r', 'refresh'),
          ('Esc', 'back'),
        ]);
      case _Screen.nodeCredentials:
        _renderNodeCredentials(s, body);
        _renderHints(s, hintRect, const [
          ('a', 'add'),
          ('x', 'remove'),
          ('r', 'refresh'),
          ('Esc', 'back'),
        ]);
      case _Screen.tunnels:
        _renderTunnels(s, body);
        _renderHints(s, hintRect, const [
          ('↑↓', 'move'),
          ('o', 'open'),
          ('c', 'close'),
          ('r', 'refresh'),
          ('Tab', 'tab'),
          ('^Q', 'quit'),
        ]);
      case _Screen.drive:
        _renderDrive(s, body);
        _renderHints(s, hintRect, const [
          ('Enter', 'open'),
          ('m', 'mount'),
          ('s', 'sync'),
          ('u', 'unmount'),
          ('R', 'remount'),
          ('r', 'refresh'),
          ('Tab', 'tab'),
        ]);
      case _Screen.driveDetail:
        _renderDriveDetail(s, body);
        _renderHints(s, hintRect, const [
          ('s', 'sync'),
          ('w', 'watch'),
          ('x', 'resolve'),
          ('D', 'diff'),
          ('r', 'refresh'),
          ('Esc', 'back'),
        ]);
      case _Screen.ai:
        _renderAi(s, body);
        _renderHints(s, hintRect, const [
          ('e', 'edit'),
          ('t', 'test'),
          ('r', 'refresh'),
          ('Tab', 'tab'),
          ('^Q', 'quit'),
        ]);
    }

    _renderStatus(s, statusRect);

    final form = _form;
    if (form != null) _renderForm(s, full, form);

    final confirm = _confirm;
    if (confirm != null) {
      InputDialog.render(
        s,
        full,
        title: confirm.title,
        value: '',
        hint: confirm.hint,
        borderStyle: Palette.dialogBg.copyWith(fg: _accent),
      );
    }

    final pager = _pager;
    if (pager != null) _renderPager(s, full, pager);

    _terminal.present(s);
    _screen = s;
  }

  /// Draws the top-level tab strip and returns the remaining body rect below it.
  Rect _renderTabBar(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return area;
    final (barRect, body) = area.splitTop(1);
    s.fillRect(
      barRect.left,
      barRect.top,
      barRect.width,
      1,
      ' ',
      Palette.tabBarBg,
    );
    var x = barRect.left + 1;
    final active = _activeTab;
    for (var i = 0; i < _tabs.length; i++) {
      if (x >= barRect.right) break;
      final selected = _tabs[i] == active;
      final style = selected ? Palette.tabActive : Palette.tabInactive;
      final label = ' ${i + 1} ${_tabLabels[i]} ';
      s.fillRect(x, barRect.top, label.length, 1, ' ', style);
      x = s.drawText(x, barRect.top, label, style, maxWidth: barRect.right - x);
      x += 1;
    }
    return body;
  }

  /// Renders a modal [_Form] centred over [full].
  void _renderForm(ScreenBuffer s, Rect full, _Form form) {
    final rows = form.fields.length + 4; // title + fields + submit + padding
    final w = (full.width - 8).clamp(20, 74);
    final h = rows.clamp(3, full.height);
    final x = full.left + ((full.width - w) ~/ 2).clamp(0, full.width);
    final y = full.top + ((full.height - h) ~/ 2).clamp(0, full.height);
    s.fillRect(x, y, w, h, ' ', Palette.panelBg);
    s.drawText(
      x + 2,
      y,
      form.title,
      Palette.panelBg.copyWith(fg: _accent, bold: true),
      maxWidth: w - 4,
    );
    var fy = y + 2;
    for (var i = 0; i < form.fields.length; i++) {
      if (fy >= y + h - 1) break;
      final f = form.fields[i];
      final shown = switch (f.kind) {
        _FieldKind.secret => '•' * f.value.length,
        _FieldKind.toggle => f.isOn ? 'yes' : 'no',
        _ => f.value,
      };
      fy = _fieldRow(
        s,
        x + 2,
        fy,
        w - 4,
        f.label,
        shown,
        focused: form.focus == i,
        caret: f.kind == _FieldKind.text || f.kind == _FieldKind.secret,
      );
    }
    if (fy < y + h) {
      final focused = form.focus == form.fields.length;
      final style = focused
          ? _barStyle.copyWith(bold: true)
          : Palette.tabInactive;
      s.fillRect(x + 2, fy, 12, 1, ' ', style);
      s.drawText(x + 4, fy, 'Submit', style);
      final hint = form.hint;
      if (hint != null && fy + 15 < x + w) {
        s.drawText(
          x + 16,
          fy,
          hint,
          Palette.panelBg.copyWith(fg: const Color.indexed(245)),
          maxWidth: (x + w) - (x + 16) - 1,
        );
      }
    }
  }

  /// Renders a full-screen [_Pager] over [full].
  void _renderPager(ScreenBuffer s, Rect full, _Pager pager) {
    s.fillRect(
      full.left,
      full.top,
      full.width,
      full.height,
      ' ',
      Palette.panelBg,
    );
    _bar(
      s,
      Rect(full.left, full.top, full.width, 1),
      ' ${pager.title}',
      _barStyle.copyWith(bold: true),
    );
    final listTop = full.top + 1;
    final listH = (full.height - 2).clamp(0, full.height);
    for (var i = 0; i < listH; i++) {
      final idx = pager.scroll + i;
      if (idx >= pager.lines.length) break;
      s.drawText(
        full.left + 1,
        listTop + i,
        pager.lines[idx],
        Palette.panelBg.copyWith(fg: const Color.indexed(252)),
        maxWidth: full.width - 2,
      );
    }
    _bar(
      s,
      Rect(full.left, full.bottom - 1, full.width, 1),
      ' ↑↓/PgUp/PgDn scroll · Esc/q close',
      Palette.hintBar,
    );
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
      Palette.editorBg.copyWith(fg: _accent, bold: true),
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
        final style = focused ? _rowSelected : _rowNormal;
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
          ? _barStyle.copyWith(bold: true)
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
    final valueStyle = focused ? _rowSelected : _rowNormal;
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
    _bar(s, _row(header, 0), ' Nodes', _barStyle.copyWith(bold: true));
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
      final style = selected ? _rowSelected : _rowNormal;
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
          style.copyWith(fg: _accentDim),
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
      _barStyle.copyWith(bold: true),
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
    final base = selected ? _rowSelected : _rowNormal;
    final muted = base.copyWith(fg: Color.indexed(selected ? 250 : 245));
    s.fillRect(listRect.left, y, listRect.width, 1, ' ', base);
    final right = listRect.right - 1;

    if (ses.shortId == _lastSessionRef) {
      s.setCell(listRect.left + 1, y, '▸', base.copyWith(fg: _accent));
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

  // ---- Tunnels / Drive / AI rendering --------------------------------------

  void _renderNodeCredentials(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return;
    final (header, listRect) = area.splitTop(1);
    _bar(
      s,
      header,
      ' ${_pad('HOST', 30)} CREDENTIAL (yours, masked)',
      Palette.tabInactive.copyWith(bold: true),
    );
    _credScroll = _ensureVisible(
      _credSel,
      _credScroll,
      listRect.height,
      _credentials.length,
    );
    if (_credentials.isEmpty) {
      s.drawText(
        listRect.left + 1,
        listRect.top,
        'No credentials for you on this node. Press a to add, r to refresh.',
        Palette.treeFile.copyWith(fg: const Color.indexed(245)),
      );
      return;
    }
    for (var i = 0; i < listRect.height; i++) {
      final idx = _credScroll + i;
      if (idx >= _credentials.length) break;
      final e = _credentials[idx];
      final y = listRect.top + i;
      final selected = idx == _credSel;
      final style = selected ? _rowSelected : _rowNormal;
      s.fillRect(listRect.left, y, listRect.width, 1, ' ', style);
      s.drawText(
        listRect.left + 1,
        y,
        '${_pad(e.host, 30)} ${e.description}',
        style,
        maxWidth: listRect.width - 2,
      );
    }
  }

  void _renderTunnels(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return;
    final (header, listRect) = area.splitTop(1);
    _bar(
      s,
      header,
      ' ${_pad('ID', 10)} ${_pad('PUBLIC', 26)} ${_pad('NODE', 16)} TARGET',
      Palette.tabInactive.copyWith(bold: true),
    );
    _tunnelScroll = _ensureVisible(
      _tunnelSel,
      _tunnelScroll,
      listRect.height,
      _tunnels.length,
    );
    if (_tunnels.isEmpty) {
      s.drawText(
        listRect.left + 1,
        listRect.top,
        'No tunnels. Press o to open one, r to refresh.',
        Palette.treeFile.copyWith(fg: const Color.indexed(245)),
      );
      return;
    }
    for (var i = 0; i < listRect.height; i++) {
      final idx = _tunnelScroll + i;
      if (idx >= _tunnels.length) break;
      final t = _tunnels[idx];
      final y = listRect.top + i;
      final selected = idx == _tunnelSel;
      final style = selected ? _rowSelected : _rowNormal;
      s.fillRect(listRect.left, y, listRect.width, 1, ' ', style);
      final host = t.publicHost.isEmpty ? '(hub)' : t.publicHost;
      final scheme = t.secure ? 'https://' : '';
      final node = t.nodeId.isEmpty ? '@local' : t.nodeId;
      s.drawText(
        listRect.left + 1,
        y,
        '${_pad(t.shortId, 10)} ${_pad('$scheme$host:${t.publicPort}', 26)} '
        '${_pad(node, 16)} ${t.targetHost}:${t.targetPort}',
        style,
        maxWidth: listRect.width - 2,
      );
    }
  }

  void _renderDrive(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return;
    final (header, listRect) = area.splitTop(1);
    _bar(
      s,
      header,
      ' ${_pad('ID', 22)} ${_pad('STATUS', 10)} MODE  SOURCE -> TARGET',
      Palette.tabInactive.copyWith(bold: true),
    );
    _mountScroll = _ensureVisible(
      _mountSel,
      _mountScroll,
      listRect.height,
      _mounts.length,
    );
    if (_mounts.isEmpty) {
      s.drawText(
        listRect.left + 1,
        listRect.top,
        'No mounts. Press m to mount, r to refresh.',
        Palette.treeFile.copyWith(fg: const Color.indexed(245)),
      );
      return;
    }
    for (var i = 0; i < listRect.height; i++) {
      final idx = _mountScroll + i;
      if (idx >= _mounts.length) break;
      final r = _mounts[idx];
      final y = listRect.top + i;
      final selected = idx == _mountSel;
      final style = selected ? _rowSelected : _rowNormal;
      s.fillRect(listRect.left, y, listRect.width, 1, ' ', style);
      s.drawText(
        listRect.left + 1,
        y,
        _mountLine(r),
        style,
        maxWidth: listRect.width - 2,
      );
    }
  }

  /// A compact one-line description of a mount (mirrors the CLI's `_mountLine`).
  String _mountLine(MountRecord r) {
    final src = r.isGit ? (r.gitUrl ?? 'git') : (r.localPath ?? '?');
    final mode = r.readWrite ? 'rw' : 'ro';
    return '${_pad(r.id, 22)} ${_pad(r.syncState.status.wireValue, 10)} '
        '$mode  $src -> ${r.nodeId}:${r.remotePath}';
  }

  void _renderDriveDetail(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return;
    final m = _currentMount;
    if (m == null) return;
    final st = m.syncState;
    final info = <(String, String)>[
      ('Mount', m.id),
      ('Kind', '${m.kind} (${m.readWrite ? 'read-write' : 'read-only'})'),
      ('Source', m.isGit ? (m.gitUrl ?? '?') : (m.localPath ?? '?')),
      ('Target', '${m.nodeId}:${m.remotePath}'),
      ('Status', st.status.wireValue),
      ('Synced', st.lastSyncedAt?.toIso8601String() ?? 'never'),
      if (st.lastError != null) ('Error', st.lastError!),
    ];
    var y = area.top;
    _bar(
      s,
      _row(area, 0),
      ' Mount ${m.id}${_loading ? '   (refreshing…)' : ''}',
      _barStyle.copyWith(bold: true),
    );
    y += 1;
    final labelStyle = Palette.panelBg.copyWith(fg: const Color.indexed(245));
    final valueStyle = Palette.panelBg.copyWith(fg: const Color.indexed(252));
    for (final (label, value) in info) {
      if (y >= area.bottom) break;
      s.fillRect(area.left, y, area.width, 1, ' ', Palette.panelBg);
      s.drawText(area.left + 2, y, label, labelStyle, maxWidth: 14);
      s.drawText(
        area.left + 16,
        y,
        value,
        valueStyle,
        maxWidth: (area.width - 18).clamp(1, area.width),
      );
      y++;
    }
    if (y >= area.bottom) return;
    y++;
    final c = _mountChanges;
    if (c == null) {
      s.drawText(area.left + 2, y, 'Press r to inspect changes.', labelStyle);
      return;
    }
    final lines = <(String, Color)>[
      ('Conflicts (${c.conflicts.length}):', const Color.indexed(203)),
      for (final p in c.conflicts) ('  $p', const Color.indexed(203)),
      ('Local-only (${c.localOnly.length}):', const Color.indexed(114)),
      for (final p in c.localOnly) ('  $p', const Color.indexed(114)),
      ('Node-only (${c.remoteOnly.length}):', const Color.indexed(179)),
      for (final p in c.remoteOnly) ('  $p', const Color.indexed(179)),
      if (c.unknown.isNotEmpty)
        ('Unknown (${c.unknown.length}):', const Color.indexed(245)),
      for (final p in c.unknown) ('  $p', const Color.indexed(245)),
    ];
    for (final (text, color) in lines) {
      if (y >= area.bottom) break;
      s.drawText(
        area.left + 2,
        y,
        text,
        Palette.panelBg.copyWith(fg: color),
        maxWidth: area.width - 3,
      );
      y++;
    }
  }

  void _renderAi(ScreenBuffer s, Rect area) {
    if (area.isEmpty) return;
    final d = _aiDesc;
    _bar(
      s,
      _row(area, 0),
      ' AI configuration${_loading ? '   (loading…)' : ''}',
      _barStyle.copyWith(bold: true),
    );
    if (d == null) return;
    final keyLine = d.keySet
        ? 'set (from ${d.keyFromEnv ? d.keyEnvVar : 'ai.yaml'})'
        : 'not set';
    final info = <(String, String)>[
      ('File', '${d.path}${d.fileExists ? '' : ' (missing)'}'),
      ('Provider', d.provider?.wireName ?? '(unset)'),
      ('Model', d.model ?? '(default)'),
      ('Planner', d.plannerModel ?? '(uses model)'),
      ('Executor', d.executorModel ?? '(uses model)'),
      ('Explainer', d.explainerModel ?? '(uses model)'),
      ('Mode', d.mode.wireName),
      ('Language', d.language ?? '(model default)'),
      ('Base URL', d.baseUrl ?? '(provider default)'),
      ('Max steps', '${d.maxSteps}'),
      ('Key', keyLine),
    ];
    final labelStyle = Palette.editorBg.copyWith(fg: const Color.indexed(245));
    final valueStyle = Palette.editorBg.copyWith(fg: const Color.indexed(252));
    var y = area.top + 2;
    for (final (label, value) in info) {
      if (y >= area.bottom) break;
      s.drawText(area.left + 2, y, label, labelStyle, maxWidth: 12);
      s.drawText(
        area.left + 15,
        y,
        value,
        valueStyle,
        maxWidth: (area.width - 16).clamp(1, area.width),
      );
      y++;
    }
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
    final who =
        '${_backend.principal?.displayName ?? '?'} @ ${_backend.connectedHub ?? '?'}';
    final ctx = switch (_screenId) {
      _Screen.login =>
        'Not connected — enter credentials or pick a saved session',
      _Screen.nodes => who,
      _Screen.nodeDetail =>
        '${_currentNode?.id.value ?? '?'}  ·  ${_sessions.length} session(s)',
      _Screen.nodeCredentials =>
        'Git credentials on ${_currentNode?.id.value ?? '?'}  ·  '
            '${_credentials.length} entr${_credentials.length == 1 ? 'y' : 'ies'}',
      _Screen.tunnels => '$who  ·  ${_tunnels.length} tunnel(s)',
      _Screen.drive => '$who  ·  ${_mounts.length} mount(s)',
      _Screen.driveDetail => 'Mount ${_currentMount?.id ?? '?'}',
      _Screen.ai => 'AI config  ·  ${_aiDesc?.path ?? '~/.omnyshell/ai.yaml'}',
    };
    _bar(s, r, ctx, _barStyle);
  }

  void _renderHints(ScreenBuffer s, Rect r, List<(String, String)> hints) {
    if (r.isEmpty) return;
    s.fillRect(r.left, r.top, r.width, 1, ' ', Palette.hintBar);
    var x = r.left + 1;
    for (final (key, label) in hints) {
      if (x >= r.right) break;
      x = s.drawText(
        x,
        r.top,
        key,
        Palette.hintBar.copyWith(fg: _accent, bold: true),
      );
      x = s.drawText(x + 1, r.top, label, Palette.hintBar) + 2;
    }
  }

  // ---- Theme ---------------------------------------------------------------

  // A monochrome (blue-free) dashboard theme. Kept local to the dashboard so the
  // shared IDE [Palette] (used by `:ide`) is unaffected. Semantic colours —
  // online-green, success-green, error-red — are intentionally left in place.

  /// Primary accent: titles, the last-interacted marker, hint keys, focus.
  static const _accent = Color.indexed(253);

  /// Secondary accent: section headings and secondary labels.
  static const _accentDim = Color.indexed(245);

  /// The status line and section-header bars (replaces the blue [Palette.statusBar]).
  static const _barStyle = Style(
    fg: Color.indexed(231),
    bg: Color.indexed(238),
  );

  // ---- Small helpers -------------------------------------------------------

  /// The background for a selected/focused list row — a neutral mid-gray that
  /// stands out clearly from the near-black unselected row background
  /// ([_rowNormal]) and does not collide with the green/amber/red status colours
  /// used in the session table.
  static const _rowSelected = Style(
    fg: Color.indexed(231),
    bg: Color.indexed(240),
    bold: true,
  );

  /// The background for an unselected list row.
  static const _rowNormal = Palette.treeFile;

  Style get _heading => Palette.editorBg.copyWith(fg: _accentDim, bold: true);

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
