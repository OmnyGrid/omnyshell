import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tui/key.dart';
import 'command_runner.dart';

/// The state and behaviour of the IDE's integrated terminal panel: a scrollback
/// of output [lines], the current [input] line, a persistent working directory
/// [cwd], and command history. Commands are executed via an injected
/// [CommandRunner]; simple `cd` commands are intercepted so the working
/// directory persists between commands (other shell state — exported variables,
/// shell functions — does not, since each command runs in a fresh shell).
///
/// Rendering lives in `widgets/terminal_view.dart`; this class is pure logic
/// (plus `dart:io` for `cd` directory checks) so it can be driven in tests.
class TerminalPanel {
  TerminalPanel({
    required String cwd,
    required CommandRunner runner,
    required void Function() onChange,
    int maxLines = 2000,
  }) : _cwd = p.normalize(cwd),
       _runner = runner,
       _onChange = onChange,
       _maxLines = maxLines;

  final CommandRunner _runner;

  /// Called when asynchronous output or completion changes the panel, so the
  /// host can repaint. Synchronous key handling does not call this — the IDE's
  /// input loop already repaints after each key.
  final void Function() _onChange;

  final int _maxLines;

  String _cwd;
  final List<String> _lines = [];
  String _input = '';
  int _scroll = 0; // lines scrolled up from the bottom
  CommandExecution? _running;
  StreamSubscription<String>? _outputSub;
  final List<String> _history = [];
  int _historyIndex = 0; // == _history.length means "editing a new line"

  String get cwd => _cwd;
  String get input => _input;
  List<String> get lines => List.unmodifiable(_lines);
  bool get isRunning => _running != null;

  /// How many lines the view is scrolled up from the bottom (0 = bottom).
  int get scroll => _scroll;

  // ---- Key handling --------------------------------------------------------

  /// Handles a key while the panel has focus. Does not trigger a repaint itself
  /// (the caller repaints after dispatching the key).
  void handleKey(KeyEvent key) {
    switch (key.type) {
      case KeyType.enter:
        _submit();
      case KeyType.backspace:
        if (_input.isNotEmpty) {
          _input = _input.substring(0, _input.length - 1);
        }
      case KeyType.char:
        _input += key.text;
        _scroll = 0;
      case KeyType.up:
        _historyPrev();
      case KeyType.down:
        _historyNext();
      case KeyType.pageUp:
        _scroll += 5;
      case KeyType.pageDown:
        _scroll = (_scroll - 5).clamp(0, 1 << 30);
      case KeyType.home:
        _scroll = 1 << 30; // clamped to the top on render
      case KeyType.end:
        _scroll = 0;
      default:
        break;
    }
  }

  void _submit() {
    final cmd = _input.trim();
    _input = '';
    _scroll = 0;
    _append('\$ $cmd');
    if (cmd.isEmpty) return;
    _history.add(cmd);
    _historyIndex = _history.length;
    if (_running != null) {
      _append('A command is already running.');
      return;
    }
    if (_tryCd(cmd)) return;
    _start(cmd);
  }

  void _start(String cmd) {
    final exec = _runner.run(cmd, _cwd);
    _running = exec;

    // Finish only once the output stream has drained *and* the exit code is
    // known, so no output is dropped regardless of which completes first.
    var streamDone = false;
    int? code;
    void maybeFinish() {
      if (!streamDone || code == null || _running != exec) return;
      _outputSub = null;
      _running = null;
      if (code != 0) _append('[exit $code]');
      _onChange();
    }

    _outputSub = exec.output.listen(
      (line) {
        _append(line);
        _onChange();
      },
      onError: (Object e) => _append('[error: $e]'),
      onDone: () {
        streamDone = true;
        maybeFinish();
      },
    );
    exec.exitCode
        .then((c) {
          code = c;
          maybeFinish();
        })
        .catchError((Object e) {
          _append('[error: $e]');
          streamDone = true;
          code = -1;
          maybeFinish();
        });
  }

  /// Intercepts a simple `cd` / `cd <dir>` so the working directory persists.
  /// Compound commands (containing operators) are left to run in a sub-shell,
  /// where a `cd` would not persist — returns false for those.
  bool _tryCd(String cmd) {
    if (cmd != 'cd' && !cmd.startsWith('cd ')) return false;
    if (cmd.contains('&&') ||
        cmd.contains('||') ||
        cmd.contains('|') ||
        cmd.contains(';')) {
      return false;
    }
    final arg = cmd == 'cd' ? '' : cmd.substring(3).trim();
    final target = _resolveCd(arg);
    if (target == null) {
      _append('cd: HOME not set');
      return true;
    }
    final dir = Directory(target);
    if (!dir.existsSync()) {
      _append('cd: no such file or directory: ${arg.isEmpty ? '~' : arg}');
      return true;
    }
    _cwd = p.normalize(dir.absolute.path);
    return true;
  }

  String? _resolveCd(String arg) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (arg.isEmpty || arg == '~') return home;
    var a = arg;
    if (a.startsWith('~/') && home != null) {
      a = p.join(home, a.substring(2));
    }
    return p.isAbsolute(a) ? a : p.join(_cwd, a);
  }

  void _historyPrev() {
    if (_history.isEmpty) return;
    if (_historyIndex > 0) _historyIndex--;
    _input = _history[_historyIndex];
  }

  void _historyNext() {
    if (_historyIndex < _history.length) _historyIndex++;
    _input = _historyIndex == _history.length ? '' : _history[_historyIndex];
  }

  void _append(String text) {
    for (final raw in text.split('\n')) {
      _lines.add(_sanitize(raw));
    }
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
  }

  /// Strips ANSI escape sequences and stray control characters from a line, so
  /// shell colour codes don't render as garbage (the panel has no VT emulator).
  static String _sanitize(String s) {
    return s
        .replaceAll(_csi, '')
        .replaceAll(_osc, '')
        .replaceAll('\r', '')
        .replaceAll('\t', '  ')
        .replaceAll(_otherCtrl, '');
  }

  static final RegExp _csi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');
  static final RegExp _osc = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');
  static final RegExp _otherCtrl = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

  /// Cancels any running command and releases resources (called on IDE exit).
  Future<void> dispose() async {
    await _outputSub?.cancel();
    _outputSub = null;
    _running?.kill();
    _running = null;
  }
}
