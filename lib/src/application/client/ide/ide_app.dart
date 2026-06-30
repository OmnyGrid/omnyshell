import 'dart:async';
import 'dart:io';

import 'package:command_shield/command_shield.dart';
import 'package:path/path.dart' as p;

import '../../../version.dart';
import '../../ai/providers/ai_provider.dart';
import 'agent/agent_backend.dart';
import 'agent/agent_panel.dart';
import 'git/git_repo.dart';
import 'git/git_status.dart';
import 'model/editor_tab.dart';
import 'model/file_tree.dart';
import 'syntax/highlighter.dart';
import 'syntax/highlighter_registry.dart';
import 'terminal/command_runner.dart';
import 'terminal/terminal_panel.dart';
import 'tui/geometry.dart';
import 'tui/key.dart';
import 'tui/key_decoder.dart';
import 'tui/screen_buffer.dart';
import 'tui/style.dart';
import 'tui/terminal.dart';
import 'widgets/agent_view.dart';
import 'widgets/editor_view.dart';
import 'widgets/file_tree_view.dart';
import 'widgets/hint_bar.dart';
import 'widgets/input_dialog.dart';
import 'widgets/palette.dart';
import 'widgets/status_bar.dart';
import 'widgets/tab_bar.dart';
import 'widgets/terminal_view.dart';

/// Which pane currently receives key input.
enum Focus { tree, editor, terminal, ai }

/// A modal text prompt (e.g. the `Ctrl-L` "go to line" dialog). While one is
/// active it captures all key input: characters build up [input], Enter calls
/// [onSubmit] with the result, and Esc dismisses it.
class _Prompt {
  _Prompt({
    required this.title,
    required this.onSubmit,
    this.hint,
    this.digitsOnly = false,
    String initial = '',
  }) : input = initial;

  final String title;
  final String? hint;
  final bool digitsOnly;
  final void Function(String value) onSubmit;
  String input;
}

/// A pending yes/no command confirmation (from the agent's `run_command` tool).
/// Resolves [completer] when the user answers; the agent loop awaits it.
class _Confirm {
  _Confirm({
    required this.command,
    required this.hint,
    required this.completer,
  });

  final String command;
  final String hint;
  final Completer<bool> completer;
}

/// The full-screen TUI IDE: a file-tree sidebar, a tab bar of open files, a
/// syntax-highlighted editor with a git-change gutter, and a status bar.
///
/// [run] takes over the terminal (via [Terminal]) until the user quits with
/// `Ctrl-Q`, then restores it. The layout, focus, key routing and render loop
/// all live here; the panes are pure renderers and the models hold the state.
///
/// Key bindings:
/// * `Ctrl-Q` quit (guards unsaved changes), `Ctrl-S` save, `Ctrl-W` close tab
///   (both guard unsaved changes with a confirm-again prompt).
/// * `Ctrl-F` find text, `Ctrl-L` go to line — each opens a modal prompt.
/// * `Ctrl-T` toggle/focus the integrated terminal panel; type a command and
///   Enter to run it (working directory persists via `cd`); `Esc` returns to
///   the editor.
/// * `Ctrl-A` toggle/focus the AI agent panel; it operates with the open file
///   or the selected directory as context and can read/edit files, search and
///   run commands. `Esc` returns to the editor.
/// * `Ctrl-B` toggle focus between tree and editor; `Tab`/`Esc` also switch.
/// * `Ctrl-N`/`Ctrl-P` next/previous tab.
/// * Tree: arrows/PageUp/Down/Home/End navigate, Enter/→ open or expand, ←
///   collapse/parent, `.` toggle hidden files, `n` new file, `N` new folder.
/// * Editor: arrows/Home/End/PageUp/Down move; typing edits; Tab inserts two
///   spaces.
class IdeApp {
  IdeApp({
    required String rootPath,
    TerminalDriver? terminal,
    Stream<List<int>>? input,
    HighlighterRegistry? registry,
    GitRepo? repo,
    DirLister? lister,
    CommandRunner? commandRunner,
    AgentBackend? agentBackend,
    AiProvider? aiProvider,
    String? aiModel,
    CommandShield? shield,
    this.theme = TokenTheme.dark,
  }) : rootPath = p.normalize(rootPath),
       _terminal = terminal ?? Terminal(inputOverride: input),
       _registry = registry ?? HighlighterRegistry(),
       _repo = repo ?? GitRepo.discover(p.normalize(rootPath)),
       _tree = FileTree(rootPath, lister: lister),
       _commandRunner = commandRunner ?? const ProcessCommandRunner(),
       _agentBackend = agentBackend,
       _aiProvider = aiProvider,
       _aiModel = aiModel,
       _shield = shield ?? CommandShield(),
       _commandSyntax = Platform.isWindows
           ? CommandSyntax.windowsCmd
           : CommandSyntax.bash;

  final String rootPath;
  final TerminalDriver _terminal;
  final HighlighterRegistry _registry;
  final GitRepo? _repo;
  final FileTree _tree;
  final CommandRunner _commandRunner;
  final TokenTheme theme;

  /// AI backend: an explicitly injected one (tests/fakes) takes precedence;
  /// otherwise built lazily from [_aiProvider], or a stub when neither is set.
  AgentBackend? _agentBackend;
  final AiProvider? _aiProvider;
  final String? _aiModel;

  /// Gates the agent's `run_command` tool: classifies risk, blocks
  /// deny/critical, and confirms anything not provably safe.
  final CommandShield _shield;
  final CommandSyntax _commandSyntax;

  final List<EditorTab> _tabs = [];
  int _activeTab = -1;

  Focus _focus = Focus.tree;
  int _treeSelected = 0;
  int _treeScroll = 0;

  /// The integrated terminal panel, created on first open; null until then.
  TerminalPanel? _terminalPanel;
  bool _showTerminal = false;

  /// The AI agent panel, created on first open; null until then.
  AgentPanel? _agentPanel;
  bool _showAgent = false;

  /// A pending command-confirmation request from the agent's run_command tool.
  _Confirm? _confirm;

  Map<String, GitFileStatus> _statusByAbs = const {};
  String? _branch;

  String? _message;
  bool _messageIsError = false;
  bool _quitArmed = false;
  bool _closeArmed = false;

  /// The active modal prompt (Ctrl-L / Ctrl-F), or null when none is open.
  _Prompt? _prompt;

  /// The last text searched with Ctrl-F, pre-filled on the next Find.
  String _lastQuery = '';

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
      await _terminalPanel?.dispose();
      if (_confirm != null && !_confirm!.completer.isCompleted) {
        _confirm!.completer.complete(false);
      }
      _agentBackend?.close();
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
    final (aboveStatus, statusRect) = full.splitBottom(1);
    // Reserve a persistent key-hint strip above the status bar, but only when
    // the terminal is tall enough to spare the row.
    final showHints = rows >= 6;
    final (content, hintRect) = showHints
        ? aboveStatus.splitBottom(1)
        : (aboveStatus, Rect.empty);

    // Carve the bottom dock (terminal or AI agent panel) from the content area,
    // spanning the full width (below both the tree and the editor).
    final showDock = _showTerminal || _showAgent;
    var main = content;
    var dockRect = Rect.empty;
    if (showDock && content.height >= 8) {
      final h = (content.height * 0.4).round().clamp(5, content.height - 4);
      (main, dockRect) = content.splitBottom(h);
    }

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

    // Bottom dock: the terminal or the AI agent panel.
    if (_showTerminal && _terminalPanel != null && !dockRect.isEmpty) {
      final termCursor = TerminalView.render(
        screen,
        dockRect,
        panel: _terminalPanel!,
        focused: _focus == Focus.terminal,
      );
      if (_focus == Focus.terminal) cursor = termCursor;
    } else if (_showAgent && _agentPanel != null && !dockRect.isEmpty) {
      final aiCursor = AgentView.render(
        screen,
        dockRect,
        panel: _agentPanel!,
        focused: _focus == Focus.ai,
      );
      if (_focus == Focus.ai) cursor = aiCursor;
    }

    // Persistent key-hint strip (tree-only keys come first when it's focused).
    if (showHints) {
      HintBar.render(screen, hintRect, treeFocused: _focus == Focus.tree);
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
      language: tab?.highlighter.language ?? 'OmnyShell IDE',
      branch: _branch,
      message: _message,
      messageIsError: _messageIsError,
    );

    // A modal prompt draws on top of everything and owns the caret.
    final prompt = _prompt;
    if (prompt != null) {
      cursor = InputDialog.render(
        screen,
        full,
        title: prompt.title,
        value: prompt.input,
        hint: prompt.hint,
      );
    }

    // A command-confirmation request (from the agent's run_command) takes the
    // very top, showing no caret.
    final confirm = _confirm;
    if (confirm != null) {
      InputDialog.render(
        screen,
        full,
        title: 'Run command?',
        value: confirm.command,
        hint: confirm.hint,
      );
    }

    final showCursor =
        confirm == null &&
        (prompt != null ||
            _focus == Focus.editor ||
            _focus == Focus.terminal ||
            _focus == Focus.ai);
    if (cursor != null && showCursor) {
      _terminal.present(screen, cursorX: cursor.x, cursorY: cursor.y);
    } else {
      _terminal.present(screen);
    }
    _screen = screen;
  }

  void _renderWelcome(ScreenBuffer screen, Rect rect) {
    final title = Palette.editorBg.copyWith(
      fg: const Color.indexed(81),
      bold: true,
    );
    final faint = Palette.editorBg.copyWith(fg: const Color.indexed(240));
    final body = Palette.editorBg.copyWith(fg: const Color.indexed(245));
    final heading = Palette.editorBg.copyWith(
      fg: const Color.indexed(109),
      bold: true,
    );
    final keyStyle = Palette.editorBg.copyWith(
      fg: const Color.indexed(81),
      bold: true,
    );

    const cellW = 20;
    const cardW = cellW * 3; // three shortcut columns

    // Build the card as a list of one-line renderers, then centre the block.
    final rows = <void Function(int x, int y)>[];
    void blank() => rows.add((_, _) {});
    void centre(String text, Style style) => rows.add((x, y) {
      final cx = x + ((cardW - text.length) ~/ 2).clamp(0, cardW);
      screen.drawText(cx, y, text, style, maxWidth: cardW);
    });
    void section(String label) => rows.add((x, y) {
      screen.drawText(x, y, label.toUpperCase(), heading, maxWidth: cardW);
    });
    void shortcuts(List<(String, String)> cells) => rows.add((x, y) {
      for (var i = 0; i < cells.length; i++) {
        final cellX = x + i * cellW + 2;
        final (key, label) = cells[i];
        final after = screen.drawText(cellX, y, key, keyStyle);
        screen.drawText(after + 1, y, label, body, maxWidth: x + cardW - after);
      }
    });

    centre('◆  OmnyShell IDE', title);
    centre('v$omnyShellVersion', faint);
    blank();
    centre('Open a file from the tree and press Enter to edit.', body);
    blank();
    section('File tree');
    shortcuts([('n', 'new file'), ('N', 'new folder'), ('.', 'hidden')]);
    blank();
    section('Editor');
    shortcuts([('^S', 'save'), ('^F', 'find'), ('^L', 'go to line')]);
    shortcuts([('^B', 'focus pane'), ('^N/^P', 'tabs'), ('^W', 'close tab')]);
    blank();
    section('Panels');
    shortcuts([('^T', 'terminal'), ('^A', 'AI agent'), ('^Q', 'quit')]);

    final top =
        rect.top + ((rect.height - rows.length) ~/ 2).clamp(0, rect.height);
    final left = rect.left + ((rect.width - cardW) ~/ 2).clamp(0, rect.width);
    for (var i = 0; i < rows.length; i++) {
      final y = top + i;
      if (y < rect.top || y >= rect.bottom) continue;
      rows[i](left, y);
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
    // A pending command confirmation takes precedence over everything.
    final confirm = _confirm;
    if (confirm != null) {
      _handleConfirmKey(key, confirm);
      return;
    }

    // A modal prompt (Ctrl-L / Ctrl-F) captures all input while open.
    final prompt = _prompt;
    if (prompt != null) {
      _handlePromptKey(key, prompt);
      return;
    }

    // Clear a transient message on the next key, except for the keys that drive
    // a confirm-again flow (quit / close tab), which own the message.
    if (_message != null && !key.isCtrl('q') && !key.isCtrl('w')) {
      _message = null;
      _messageIsError = false;
    }

    // Global bindings first. Ctrl-Q and Ctrl-W keep their own "armed" flag alive
    // across a repeat press; any other key cancels both pending confirmations.
    if (key.isCtrl('q')) {
      _closeArmed = false;
      _tryQuit();
      return;
    }
    if (key.isCtrl('w')) {
      _quitArmed = false;
      _closeActiveTab();
      return;
    }
    _quitArmed = false;
    _closeArmed = false;
    if (key.isCtrl('s')) {
      _saveActive();
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
    if (key.isCtrl('l')) {
      _promptGotoLine();
      return;
    }
    if (key.isCtrl('f')) {
      _promptFind();
      return;
    }
    if (key.isCtrl('t')) {
      _toggleTerminal();
      return;
    }
    if (key.isCtrl('a')) {
      _toggleAgent();
      return;
    }

    // The terminal panel captures input (except the global bindings above) while
    // focused; Esc hands focus back to the editor/tree.
    if (_focus == Focus.terminal) {
      if (key.type == KeyType.escape) {
        _focus = _tabs.isNotEmpty ? Focus.editor : Focus.tree;
      } else {
        _terminalPanel?.handleKey(key);
      }
      return;
    }
    if (_focus == Focus.ai) {
      if (key.type == KeyType.escape) {
        _focus = _tabs.isNotEmpty ? Focus.editor : Focus.tree;
      } else {
        _agentPanel?.handleKey(key);
      }
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
        switch (key.text) {
          case '.':
            _tree.toggleHidden();
          case 'n':
            _promptNewEntry(isDir: false);
          case 'N':
            _promptNewEntry(isDir: true);
        }
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

  /// Routes a key to the open modal [prompt]: Enter submits, Esc dismisses,
  /// Backspace deletes, printable characters append (digits only when the prompt
  /// requests it).
  void _handlePromptKey(KeyEvent key, _Prompt prompt) {
    switch (key.type) {
      case KeyType.escape:
        _prompt = null;
      case KeyType.enter:
        _prompt = null;
        prompt.onSubmit(prompt.input);
      case KeyType.backspace:
        if (prompt.input.isNotEmpty) {
          prompt.input = prompt.input.substring(0, prompt.input.length - 1);
        }
      case KeyType.char:
        final ch = key.text;
        if (ch.isEmpty) break;
        if (prompt.digitsOnly &&
            (ch.codeUnitAt(0) < 0x30 || ch.codeUnitAt(0) > 0x39)) {
          break;
        }
        prompt.input += ch;
      default:
        break;
    }
  }

  // ---- Actions -------------------------------------------------------------

  /// Opens the Ctrl-L "go to line" prompt for the active tab.
  void _promptGotoLine() {
    final tab = _activeTab >= 0 ? _tabs[_activeTab] : null;
    if (tab == null) {
      _setMessage('Open a file first to go to a line.', isError: true);
      return;
    }
    _prompt = _Prompt(
      title: 'Go to line',
      hint: '1–${tab.document.lineCount}, Enter to jump · Esc to cancel',
      digitsOnly: true,
      onSubmit: _gotoLine,
    );
  }

  /// Moves the caret to line [value] (1-based), clamped to the file's range.
  void _gotoLine(String value) {
    final tab = _activeTab >= 0 ? _tabs[_activeTab] : null;
    if (tab == null) return;
    final n = int.tryParse(value.trim());
    if (n == null || n < 1) {
      _setMessage('Invalid line number.', isError: true);
      return;
    }
    final doc = tab.document;
    final target = n.clamp(1, doc.lineCount);
    doc.moveTo(target - 1, 0);
    _focus = Focus.editor;
    if (target != n) {
      _setMessage('Line $n is out of range — moved to line $target.');
    }
  }

  /// Opens the Ctrl-F "find" prompt for the active tab, pre-filled with the last
  /// query so Enter repeats the previous search.
  void _promptFind() {
    final tab = _activeTab >= 0 ? _tabs[_activeTab] : null;
    if (tab == null) {
      _setMessage('Open a file first to search.', isError: true);
      return;
    }
    _prompt = _Prompt(
      title: 'Find',
      hint: 'Enter to find next · Esc to cancel',
      initial: _lastQuery,
      onSubmit: _find,
    );
  }

  /// Finds [query] forward from the caret (case-insensitive, wrapping once) and
  /// moves the caret to the next match. An empty [query] repeats [_lastQuery].
  void _find(String query) {
    final tab = _activeTab >= 0 ? _tabs[_activeTab] : null;
    if (tab == null) return;
    var q = query;
    if (q.isEmpty) q = _lastQuery;
    if (q.isEmpty) {
      _setMessage('Nothing to find.', isError: true);
      return;
    }
    _lastQuery = q;
    final doc = tab.document;
    final lines = doc.lines;
    final needle = q.toLowerCase();
    final startRow = doc.cursorRow;
    final startCol = doc.cursorCol + 1; // skip the current position
    // Scan each line once from the cursor, wrapping back to the start line.
    for (var i = 0; i <= lines.length; i++) {
      final row = (startRow + i) % lines.length;
      final hay = lines[row].toLowerCase();
      final from = i == 0 ? startCol.clamp(0, hay.length) : 0;
      final idx = hay.indexOf(needle, from);
      if (idx >= 0) {
        doc.moveTo(row, idx);
        _focus = Focus.editor;
        _setMessage('Found "$q" at line ${row + 1}.');
        return;
      }
    }
    _setMessage('"$q" not found.', isError: true);
  }

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

  /// Ctrl-T: open and focus the terminal panel; if it's already focused, hide
  /// it; if it's visible but unfocused, focus it. The bottom dock hosts one
  /// panel at a time, so opening the terminal hides the AI panel.
  void _toggleTerminal() {
    if (_showTerminal && _focus == Focus.terminal) {
      _showTerminal = false;
      _focus = _tabs.isNotEmpty ? Focus.editor : Focus.tree;
      return;
    }
    if (_showTerminal) {
      _focus = Focus.terminal;
      return;
    }
    _terminalPanel ??= TerminalPanel(
      cwd: rootPath,
      runner: _commandRunner,
      onChange: () {
        if (!_done.isCompleted) _render();
      },
    );
    _showAgent = false;
    _showTerminal = true;
    _focus = Focus.terminal;
  }

  /// Ctrl-A: open/focus/hide the AI agent panel (mirrors [_toggleTerminal]).
  /// On open or refocus it recaptures the context (active file or selected
  /// directory). Shares the bottom dock with the terminal.
  void _toggleAgent() {
    if (_showAgent && _focus == Focus.ai) {
      _showAgent = false;
      _focus = _tabs.isNotEmpty ? Focus.editor : Focus.tree;
      return;
    }
    final panel = _agentPanel ??= AgentPanel(
      backend: _ensureAgentBackend(),
      onChange: () {
        if (!_done.isCompleted) _render();
      },
    );
    panel.setContext(_captureAgentContext());
    _showTerminal = false;
    _showAgent = true;
    _focus = Focus.ai;
  }

  AgentBackend _ensureAgentBackend() {
    final provider = _aiProvider;
    return _agentBackend ??= provider != null
        ? ProviderAgentBackend(
            provider,
            model: _aiModel,
            tools: _IdeAgentTools(this),
          )
        : const UnavailableAgentBackend();
  }

  /// Captures the agent's working context from the current IDE state: a
  /// directory selected in the tree, otherwise the open file, else the root.
  AgentContext _captureAgentContext() {
    if (_focus == Focus.tree) {
      final nodes = _tree.visibleNodes();
      if (_treeSelected >= 0 && _treeSelected < nodes.length) {
        final node = nodes[_treeSelected];
        if (node.isDir) {
          return AgentContext.directory(node.path, _safeList(node.path));
        }
        return _fileContext(node.path);
      }
    }
    final tab = _activeTab >= 0 ? _tabs[_activeTab] : null;
    if (tab != null) {
      return AgentContext.file(tab.path, tab.document.toText());
    }
    return AgentContext.directory(rootPath, _safeList(rootPath));
  }

  AgentContext _fileContext(String path) {
    try {
      return AgentContext.file(path, File(path).readAsStringSync());
    } on Object {
      return AgentContext.directory(
        p.dirname(path),
        _safeList(p.dirname(path)),
      );
    }
  }

  List<String> _safeList(String dir) {
    try {
      final out =
          Directory(dir)
              .listSync()
              .map((e) => p.basename(e.path) + (e is Directory ? '/' : ''))
              .toList()
            ..sort();
      return out;
    } on Object {
      return const [];
    }
  }

  /// Resolves a yes/no command confirmation key (from the agent's run_command).
  void _handleConfirmKey(KeyEvent key, _Confirm confirm) {
    final yes =
        key.type == KeyType.enter ||
        (key.type == KeyType.char && (key.text == 'y' || key.text == 'Y'));
    final no =
        key.type == KeyType.escape ||
        (key.type == KeyType.char && (key.text == 'n' || key.text == 'N'));
    if (yes) {
      _confirm = null;
      confirm.completer.complete(true);
    } else if (no) {
      _confirm = null;
      confirm.completer.complete(false);
    }
  }

  // ---- Agent tool execution (wired to [_IdeAgentTools]) ---------------------

  EditorTab? _tabFor(String absPath) {
    final i = _tabs.indexWhere((t) => p.equals(t.path, absPath));
    return i >= 0 ? _tabs[i] : null;
  }

  /// Reloads an open tab after the agent edits its file on disk, and refreshes
  /// git status/gutter so the change is reflected immediately.
  void _onAgentEditedFile(String absPath) {
    final i = _tabs.indexWhere((t) => p.equals(t.path, absPath));
    if (i >= 0) {
      try {
        _tabs[i] = EditorTab.open(absPath, registry: _registry);
      } on Object {
        // Leave the stale tab if the reload fails (e.g. file deleted).
      }
    }
    _refreshGit();
    _refreshActiveGutter();
  }

  /// Grep-like search across workspace files (skips hidden/dot paths and binary
  /// files), returning up to a bounded number of `relpath:line: text` matches.
  List<String> _searchWorkspace(String query) {
    if (query.isEmpty) return const [];
    const maxResults = 100;
    final results = <String>[];
    try {
      for (final entity in Directory(
        rootPath,
      ).listSync(recursive: true, followLinks: false)) {
        if (results.length >= maxResults) break;
        if (entity is! File) continue;
        final rel = p.relative(entity.path, from: rootPath);
        if (p.split(rel).any((s) => s.startsWith('.'))) continue;
        String text;
        try {
          text = entity.readAsStringSync();
        } on Object {
          continue;
        }
        if (text.contains('\x00')) continue; // binary
        final lines = text.split('\n');
        for (var i = 0; i < lines.length && results.length < maxResults; i++) {
          if (lines[i].contains(query)) {
            results.add('$rel:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    } on Object {
      // Best-effort search.
    }
    return results;
  }

  /// Runs an agent-requested command through [_shield]: blocks deny/critical,
  /// confirms anything not provably safe, then executes it in the workspace.
  Future<String> _runAgentCommand(String command) async {
    final cmd = command.trim();
    if (cmd.isEmpty) return 'No command provided.';
    final verdict = _shield.validate(cmd, syntax: _commandSyntax);
    if (verdict.decision == CommandDecision.deny ||
        verdict.securityLevel == SecurityLevel.critical) {
      return 'BLOCKED by command_shield '
          '(${verdict.decision.name}/${verdict.securityLevel.name}): '
          '${_findings(verdict)}. The command was NOT run; choose a safer '
          'approach.';
    }
    if (verdict.securityLevel != SecurityLevel.safe) {
      final approved = await _confirmCommand(cmd, verdict);
      if (!approved) {
        return 'User declined to run this command. Propose an alternative or '
            'stop and explain.';
      }
    }
    return _execAgentCommand(cmd);
  }

  Future<bool> _confirmCommand(String command, CommandResult verdict) {
    final hint =
        '[${verdict.securityLevel.name}] ${_findings(verdict)}  ·  '
        'y = run · n/Esc = cancel';
    final completer = Completer<bool>();
    _confirm = _Confirm(command: command, hint: hint, completer: completer);
    if (!_done.isCompleted) _render();
    return completer.future;
  }

  Future<String> _execAgentCommand(String command) async {
    final exec = _commandRunner.run(command, rootPath);
    final buf = StringBuffer();
    final done = exec.output.forEach(buf.writeln).catchError((_) {});
    final code = await exec.exitCode.catchError((_) => -1);
    await done;
    var out = buf.toString();
    const cap = 8000;
    if (out.length > cap) out = '${out.substring(0, cap)}\n…(truncated)…';
    return '${out.trimRight()}\n[exit $code]';
  }

  String _findings(CommandResult verdict) => verdict.findings.isEmpty
      ? 'flagged ${verdict.securityLevel.name}'
      : verdict.findings.map((f) => f.message).take(2).join('; ');

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
    if (tab.document.dirty && !_closeArmed) {
      _closeArmed = true;
      _setMessage(
        'Unsaved changes! Ctrl-S to save, or Ctrl-W again to discard and close.',
        isError: true,
      );
      return;
    }
    _closeArmed = false;
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

  /// The directory a new tree entry should be created in: the selected node when
  /// it's a directory, else the selected file's parent, else the root.
  String _treeTargetDir() {
    final nodes = _tree.visibleNodes();
    if (_treeSelected >= 0 && _treeSelected < nodes.length) {
      final node = nodes[_treeSelected];
      return node.isDir ? node.path : p.dirname(node.path);
    }
    return rootPath;
  }

  /// Opens the "new file"/"new folder" prompt (tree `n`/`N`).
  void _promptNewEntry({required bool isDir}) {
    final dir = _treeTargetDir();
    _prompt = _Prompt(
      title: isDir ? 'New folder' : 'New file',
      hint: 'in ${_displayPath(dir)}/ · nested paths ok · Esc to cancel',
      onSubmit: (name) => _createEntry(dir, name, isDir: isDir),
    );
  }

  /// Creates a file or directory [name] (possibly a nested path) under [dir],
  /// refreshes and selects it in the tree, and opens a new file in the editor.
  void _createEntry(String dir, String name, {required bool isDir}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final abs = p.normalize(p.join(dir, trimmed));
    if (abs != rootPath && !p.isWithin(rootPath, abs)) {
      _setMessage('Path is outside the workspace.', isError: true);
      return;
    }
    try {
      if (isDir) {
        if (Directory(abs).existsSync()) {
          _setMessage('Already exists: ${_displayPath(abs)}', isError: true);
        } else {
          Directory(abs).createSync(recursive: true);
        }
      } else {
        final file = File(abs);
        if (file.existsSync()) {
          _setMessage('Already exists: ${_displayPath(abs)}', isError: true);
        } else {
          file.parent.createSync(recursive: true);
          file.createSync();
        }
      }
    } on Object catch (e) {
      _setMessage('Create failed: $e', isError: true);
      return;
    }
    _tree.refresh();
    _revealInTree(abs);
    if (!isDir) {
      _openFile(abs);
      _refreshGit();
    }
  }

  /// Reveals [absPath] in the tree (expanding ancestors) and selects its row.
  void _revealInTree(String absPath) {
    _tree.reveal(absPath);
    final nodes = _tree.visibleNodes();
    for (var i = 0; i < nodes.length; i++) {
      if (p.equals(nodes[i].path, absPath)) {
        _treeSelected = i; // the next render scrolls it into view
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

/// The IDE-side implementation of [AgentTools]: file operations scoped to the
/// workspace root (path-escape guarded), edits that flow back into open editor
/// tabs, workspace search, and shield-gated command execution — all delegated to
/// the owning [IdeApp] so the editor and git state stay in sync.
class _IdeAgentTools implements AgentTools {
  _IdeAgentTools(this._app);

  final IdeApp _app;

  String _resolve(String path) {
    final raw = path.trim();
    final abs = p.isAbsolute(raw)
        ? p.normalize(raw)
        : p.normalize(p.join(_app.rootPath, raw));
    if (abs != _app.rootPath && !p.isWithin(_app.rootPath, abs)) {
      throw StateError('path is outside the workspace: $path');
    }
    return abs;
  }

  @override
  List<String> list(String path) {
    final dir = Directory(_resolve(path));
    if (!dir.existsSync()) throw StateError('no such directory: $path');
    final out =
        dir
            .listSync()
            .map((e) => p.basename(e.path) + (e is Directory ? '/' : ''))
            .toList()
          ..sort();
    return out;
  }

  @override
  String read(String path) {
    final abs = _resolve(path);
    final tab = _app._tabFor(abs);
    if (tab != null) return tab.document.toText();
    final file = File(abs);
    if (!file.existsSync()) throw StateError('no such file: $path');
    return file.readAsStringSync();
  }

  @override
  void write(String path, String content) {
    final abs = _resolve(path);
    File(abs).parent.createSync(recursive: true);
    File(abs).writeAsStringSync(content);
    _app._onAgentEditedFile(abs);
  }

  @override
  void replace(String path, String oldString, String newString) {
    final abs = _resolve(path);
    final current = read(path);
    final first = current.indexOf(oldString);
    if (first < 0) {
      throw StateError('old_string not found in $path');
    }
    if (current.indexOf(oldString, first + oldString.length) >= 0) {
      throw StateError('old_string is not unique in $path');
    }
    File(abs).writeAsStringSync(current.replaceFirst(oldString, newString));
    _app._onAgentEditedFile(abs);
  }

  @override
  List<String> search(String query) => _app._searchWorkspace(query);

  @override
  Future<String> run(String command) => _app._runAgentCommand(command);
}
