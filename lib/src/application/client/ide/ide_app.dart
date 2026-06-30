import 'dart:async';

import 'package:path/path.dart' as p;

import 'git/git_repo.dart';
import 'git/git_status.dart';
import 'model/editor_tab.dart';
import 'model/file_tree.dart';
import 'syntax/highlighter.dart';
import 'syntax/highlighter_registry.dart';
import 'tui/geometry.dart';
import 'tui/key.dart';
import 'tui/key_decoder.dart';
import 'tui/screen_buffer.dart';
import 'tui/style.dart';
import 'tui/terminal.dart';
import 'widgets/editor_view.dart';
import 'widgets/file_tree_view.dart';
import 'widgets/palette.dart';
import 'widgets/status_bar.dart';
import 'widgets/tab_bar.dart';

/// Which pane currently receives key input.
enum Focus { tree, editor }

/// The full-screen TUI IDE: a file-tree sidebar, a tab bar of open files, a
/// syntax-highlighted editor with a git-change gutter, and a status bar.
///
/// [run] takes over the terminal (via [Terminal]) until the user quits with
/// `Ctrl-Q`, then restores it. The layout, focus, key routing and render loop
/// all live here; the panes are pure renderers and the models hold the state.
///
/// Key bindings:
/// * `Ctrl-Q` quit (guards unsaved changes), `Ctrl-S` save, `Ctrl-W` close tab.
/// * `Ctrl-B` toggle focus between tree and editor; `Tab`/`Esc` also switch.
/// * `Ctrl-N`/`Ctrl-P` next/previous tab.
/// * Tree: arrows/PageUp/Down/Home/End navigate, Enter/→ open or expand, ←
///   collapse/parent, `.` toggle hidden files.
/// * Editor: arrows/Home/End/PageUp/Down move; typing edits; Tab inserts two
///   spaces.
class IdeApp {
  IdeApp({
    required String rootPath,
    TerminalDriver? terminal,
    HighlighterRegistry? registry,
    GitRepo? repo,
    DirLister? lister,
    this.theme = TokenTheme.dark,
  }) : rootPath = p.normalize(rootPath),
       _terminal = terminal ?? Terminal(),
       _registry = registry ?? HighlighterRegistry(),
       _repo = repo ?? GitRepo.discover(p.normalize(rootPath)),
       _tree = FileTree(rootPath, lister: lister);

  final String rootPath;
  final TerminalDriver _terminal;
  final HighlighterRegistry _registry;
  final GitRepo? _repo;
  final FileTree _tree;
  final TokenTheme theme;

  final List<EditorTab> _tabs = [];
  int _activeTab = -1;

  Focus _focus = Focus.tree;
  int _treeSelected = 0;
  int _treeScroll = 0;

  Map<String, GitFileStatus> _statusByAbs = const {};
  String? _branch;

  String? _message;
  bool _messageIsError = false;
  bool _quitArmed = false;

  ScreenBuffer? _screen;
  final Completer<void> _done = Completer<void>();

  /// Runs the IDE until the user quits, restoring the terminal afterwards.
  Future<void> run() async {
    _refreshGit();
    _terminal.enter();
    final decoder = KeyDecoder();
    StreamSubscription<List<int>>? inputSub;
    StreamSubscription<void>? resizeSub;
    try {
      _render();
      inputSub = _terminal.input.listen(
        (bytes) {
          for (final key in decoder.decode(bytes)) {
            _handleKey(key);
            if (_done.isCompleted) return;
          }
          if (!_done.isCompleted) _render();
        },
        onError: (_) => _finish(),
        onDone: _finish,
      );
      resizeSub = _terminal.resizeEvents.listen((_) {
        _terminal.invalidate();
        _render();
      });
      await _done.future;
    } finally {
      await inputSub?.cancel();
      await resizeSub?.cancel();
      _terminal.leave();
    }
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  // ---- Rendering -----------------------------------------------------------

  void _render() {
    final size = _terminal.size;
    final cols = size.cols;
    final rows = size.rows;
    final screen = ScreenBuffer(cols, rows);
    screen.clear(Palette.editorBg);

    final full = Rect(0, 0, cols, rows);
    final (main, statusRect) = full.splitBottom(1);

    final treeWidth = _treeWidth(cols);
    final (treePane, afterTree) = main.splitLeft(treeWidth);
    final (sep, rightArea) = afterTree.splitLeft(treeWidth > 0 ? 1 : 0);
    if (!sep.isEmpty) {
      for (var y = sep.top; y < sep.bottom; y++) {
        screen.setCell(sep.left, y, '│', Palette.border);
      }
    }

    // File tree.
    final nodes = _tree.visibleNodes();
    if (_treeSelected >= nodes.length) _treeSelected = nodes.length - 1;
    if (_treeSelected < 0) _treeSelected = 0;
    _ensureTreeVisible(treePane.height);
    if (!treePane.isEmpty) {
      FileTreeView.render(
        screen,
        treePane,
        nodes: nodes,
        selected: _treeSelected,
        scrollTop: _treeScroll,
        statusOf: (abs) => _statusByAbs[p.normalize(abs)],
        focused: _focus == Focus.tree,
      );
    }

    // Tab bar + editor.
    final (tabRect, editorRect) = rightArea.splitTop(1);
    TabBar.render(screen, tabRect, tabs: _tabs, active: _activeTab);

    ({int x, int y})? cursor;
    final tab = _activeTab >= 0 ? _tabs[_activeTab] : null;
    if (tab != null) {
      cursor = EditorView.render(
        screen,
        editorRect,
        tab: tab,
        theme: theme,
        focused: _focus == Focus.editor,
      );
    } else if (!editorRect.isEmpty) {
      _renderWelcome(screen, editorRect);
    }

    // Status bar.
    final doc = tab?.document;
    StatusBar.render(
      screen,
      statusRect,
      path: tab == null ? rootPath : _displayPath(tab.path),
      dirty: doc?.dirty ?? false,
      readOnly: doc?.isBinary ?? false,
      line: (doc?.cursorRow ?? 0) + 1,
      column: (doc?.cursorCol ?? 0) + 1,
      language: tab?.highlighter.language ?? 'omnyShell IDE',
      branch: _branch,
      message: _message,
      messageIsError: _messageIsError,
    );

    if (_focus == Focus.editor && cursor != null) {
      _terminal.present(screen, cursorX: cursor.x, cursorY: cursor.y);
    } else {
      _terminal.present(screen);
    }
    _screen = screen;
  }

  void _renderWelcome(ScreenBuffer screen, Rect rect) {
    final lines = [
      'omnyShell IDE',
      '',
      'Select a file in the tree and press Enter to open it.',
      '',
      'Ctrl-B  focus tree/editor      Ctrl-S  save',
      'Ctrl-N/P  next/prev tab        Ctrl-W  close tab',
      'Ctrl-Q  quit',
    ];
    final startY = rect.top + (rect.height - lines.length) ~/ 2;
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i];
      final x =
          rect.left + ((rect.width - text.length) ~/ 2).clamp(0, rect.width);
      final style = i == 0
          ? Palette.editorBg.copyWith(fg: const Color.indexed(81), bold: true)
          : Palette.editorBg.copyWith(fg: const Color.indexed(245));
      screen.drawText(x, startY + i, text, style, maxWidth: rect.width);
    }
  }

  int _treeWidth(int cols) {
    if (cols < 40) return _focus == Focus.tree ? cols : 0;
    return (cols * 0.28).round().clamp(20, 46);
  }

  void _ensureTreeVisible(int height) {
    if (height <= 0) return;
    if (_treeSelected < _treeScroll) _treeScroll = _treeSelected;
    if (_treeSelected >= _treeScroll + height) {
      _treeScroll = _treeSelected - height + 1;
    }
    if (_treeScroll < 0) _treeScroll = 0;
  }

  // ---- Key handling --------------------------------------------------------

  void _handleKey(KeyEvent key) {
    // Clear a transient message on the next key (except the quit-arm flow).
    if (_message != null && !(key.isCtrl('q'))) {
      _message = null;
      _messageIsError = false;
    }

    // Global bindings first.
    if (key.isCtrl('q')) {
      _tryQuit();
      return;
    }
    _quitArmed = false;
    if (key.isCtrl('s')) {
      _saveActive();
      return;
    }
    if (key.isCtrl('w')) {
      _closeActiveTab();
      return;
    }
    if (key.isCtrl('b')) {
      _toggleFocus();
      return;
    }
    if (key.isCtrl('n')) {
      _switchTab(1);
      return;
    }
    if (key.isCtrl('p')) {
      _switchTab(-1);
      return;
    }

    if (_focus == Focus.tree) {
      _handleTreeKey(key);
    } else {
      _handleEditorKey(key);
    }
  }

  void _handleTreeKey(KeyEvent key) {
    final nodes = _tree.visibleNodes();
    switch (key.type) {
      case KeyType.up:
        if (_treeSelected > 0) _treeSelected--;
      case KeyType.down:
        if (_treeSelected < nodes.length - 1) _treeSelected++;
      case KeyType.home:
        _treeSelected = 0;
      case KeyType.end:
        _treeSelected = nodes.length - 1;
      case KeyType.pageUp:
        _treeSelected = (_treeSelected - 10).clamp(0, nodes.length - 1);
      case KeyType.pageDown:
        _treeSelected = (_treeSelected + 10).clamp(0, nodes.length - 1);
      case KeyType.right:
        final node = nodes[_treeSelected];
        if (node.isDir && !node.expanded) {
          _tree.expand(node);
        } else if (!node.isDir) {
          _openSelected();
        }
      case KeyType.left:
        final node = nodes[_treeSelected];
        if (node.isDir && node.expanded) {
          _tree.toggle(node); // collapse
        } else {
          _selectParent(nodes);
        }
      case KeyType.enter:
        final node = nodes[_treeSelected];
        if (node.isDir) {
          _tree.toggle(node);
        } else {
          _openSelected();
        }
      case KeyType.tab:
        if (_tabs.isNotEmpty) _focus = Focus.editor;
      case KeyType.char:
        if (key.text == '.') _tree.toggleHidden();
      default:
        break;
    }
  }

  void _handleEditorKey(KeyEvent key) {
    final tab = _activeTab >= 0 ? _tabs[_activeTab] : null;
    if (tab == null) {
      if (key.type == KeyType.escape || key.type == KeyType.tab) {
        _focus = Focus.tree;
      }
      return;
    }
    final doc = tab.document;
    final pageRows = _editorPageRows();
    switch (key.type) {
      case KeyType.escape:
        _focus = Focus.tree;
      case KeyType.up:
        doc.moveUp();
      case KeyType.down:
        doc.moveDown();
      case KeyType.left:
        doc.moveLeft();
      case KeyType.right:
        doc.moveRight();
      case KeyType.home:
        doc.moveHome();
      case KeyType.end:
        doc.moveEnd();
      case KeyType.pageUp:
        doc.movePageUp(pageRows);
      case KeyType.pageDown:
        doc.movePageDown(pageRows);
      case KeyType.enter:
        doc.insertNewline();
        tab.invalidateHighlight();
      case KeyType.backspace:
        doc.backspace();
        tab.invalidateHighlight();
      case KeyType.delete:
        doc.deleteForward();
        tab.invalidateHighlight();
      case KeyType.tab:
        doc.insert('  ');
        tab.invalidateHighlight();
      case KeyType.char:
        doc.insert(key.text);
        tab.invalidateHighlight();
      default:
        break;
    }
  }

  // ---- Actions -------------------------------------------------------------

  void _tryQuit() {
    final hasUnsaved = _tabs.any((t) => t.document.dirty);
    if (hasUnsaved && !_quitArmed) {
      _quitArmed = true;
      _setMessage(
        'Unsaved changes! Ctrl-S to save, or Ctrl-Q again to discard and quit.',
        isError: true,
      );
      return;
    }
    _finish();
  }

  void _toggleFocus() {
    if (_focus == Focus.tree) {
      if (_tabs.isNotEmpty) _focus = Focus.editor;
    } else {
      _focus = Focus.tree;
    }
  }

  void _switchTab(int delta) {
    if (_tabs.isEmpty) return;
    _activeTab = (_activeTab + delta) % _tabs.length;
    if (_activeTab < 0) _activeTab += _tabs.length;
    _focus = Focus.editor;
    _refreshActiveGutter();
  }

  void _openSelected() {
    final nodes = _tree.visibleNodes();
    if (_treeSelected < 0 || _treeSelected >= nodes.length) return;
    final node = nodes[_treeSelected];
    if (node.isDir) return;
    _openFile(node.path);
  }

  void _openFile(String absPath) {
    // Focus an already-open tab if present.
    final existing = _tabs.indexWhere((t) => p.equals(t.path, absPath));
    if (existing >= 0) {
      _activeTab = existing;
      _focus = Focus.editor;
      _refreshActiveGutter();
      return;
    }
    try {
      final tab = EditorTab.open(absPath, registry: _registry);
      _tabs.add(tab);
      _activeTab = _tabs.length - 1;
      _focus = Focus.editor;
      _refreshActiveGutter();
    } on Object catch (e) {
      _setMessage('Cannot open ${_displayPath(absPath)}: $e', isError: true);
    }
  }

  void _closeActiveTab() {
    if (_activeTab < 0) return;
    final tab = _tabs[_activeTab];
    if (tab.document.dirty) {
      _setMessage(
        'Unsaved changes in this tab — Ctrl-S to save before closing.',
        isError: true,
      );
      return;
    }
    _tabs.removeAt(_activeTab);
    if (_tabs.isEmpty) {
      _activeTab = -1;
      _focus = Focus.tree;
    } else {
      _activeTab = _activeTab.clamp(0, _tabs.length - 1);
    }
  }

  void _saveActive() {
    if (_activeTab < 0) return;
    final tab = _tabs[_activeTab];
    final doc = tab.document;
    if (doc.isBinary) {
      _setMessage('Binary file is read-only.', isError: true);
      return;
    }
    if (!doc.dirty) {
      _setMessage('No changes to save.');
      return;
    }
    try {
      doc.save();
      _refreshGit();
      _refreshActiveGutter();
      _setMessage('Saved ${_displayPath(tab.path)}');
    } on Object catch (e) {
      _setMessage('Save failed: $e', isError: true);
    }
  }

  void _selectParent(List<FileNode> nodes) {
    final node = nodes[_treeSelected];
    final parent = p.dirname(node.path);
    for (var i = _treeSelected - 1; i >= 0; i--) {
      if (p.equals(nodes[i].path, parent)) {
        _treeSelected = i;
        return;
      }
    }
  }

  // ---- Git -----------------------------------------------------------------

  void _refreshGit() {
    final repo = _repo;
    if (repo == null) return;
    _branch = repo.currentBranch();
    final byRel = repo.fileStatuses();
    _statusByAbs = {
      for (final entry in byRel.entries)
        p.normalize(p.join(repo.root, entry.key)): entry.value,
    };
  }

  void _refreshActiveGutter() {
    final repo = _repo;
    if (repo == null || _activeTab < 0) return;
    final tab = _tabs[_activeTab];
    if (tab.path.isEmpty) return;
    try {
      tab.gutter = repo.lineGutter(tab.path, lineCount: tab.document.lineCount);
    } on Object {
      tab.gutter = LineGutter.empty;
    }
  }

  // ---- Helpers -------------------------------------------------------------

  int _editorPageRows() {
    final rows = _terminal.size.rows;
    // Total rows minus the status bar and the tab bar.
    return (rows - 2).clamp(1, rows);
  }

  void _setMessage(String message, {bool isError = false}) {
    _message = message;
    _messageIsError = isError;
  }

  String _displayPath(String absPath) {
    if (p.isWithin(rootPath, absPath)) {
      return p.relative(absPath, from: rootPath);
    }
    return absPath;
  }

  /// The current screen buffer (for tests/inspection); `null` before first
  /// render.
  ScreenBuffer? get debugScreen => _screen;
}
