import 'dart:async';

import 'package:path/path.dart' as p;

import '../tui/key.dart';
import 'command_runner.dart';

/// The state and behaviour of the IDE's integrated terminal panel: a scrollback
/// of output [lines], the current [input] line, a persistent working directory
/// [cwd], and command history. Commands are executed via an injected
/// [CommandRunner] (local process or remote node); simple `cd` commands are
/// resolved through the runner (`cd … && pwd`) so the working directory persists
/// between commands (other shell state — exported variables, shell functions —
/// does not, since each command runs in a fresh shell).
///
/// Rendering lives in `widgets/terminal_view.dart`; this class is `dart:io`-free
/// pure logic so it can run in tests and the web client.
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
    if (_isCd(cmd)) {
      _runCd(cmd);
      return;
    }
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

  /// Whether [cmd] is a plain `cd` / `cd <dir>` we resolve ourselves. Compound
  /// commands (containing operators) run in a sub-shell where `cd` would not
  /// persist, so they are left to [_start].
  bool _isCd(String cmd) {
    if (cmd != 'cd' && !cmd.startsWith('cd ')) return false;
    return !(cmd.contains('&&') ||
        cmd.contains('||') ||
        cmd.contains('|') ||
        cmd.contains(';'));
  }

  /// Resolves a `cd` through the runner (`cd … && pwd`) so it works against the
  /// local fs or the remote node, capturing the new working directory.
  void _runCd(String cmd) {
    final arg = cmd == 'cd' ? '' : cmd.substring(3).trim();
    final probe = arg.isEmpty ? 'cd && pwd' : 'cd -- ${_q(arg)} && pwd';
    final exec = _runner.run(probe, _cwd);
    _running = exec;
    final buf = StringBuffer();
    // Finish only once output has drained *and* the exit code is known, so the
    // captured pwd is complete regardless of which completes first.
    var streamDone = false;
    int? code;
    void finish() {
      if (!streamDone || code == null) return;
      _outputSub = null;
      _running = null;
      final out = buf.toString().trim();
      if (code == 0) {
        if (out.isNotEmpty) _cwd = out.split('\n').last.trim();
      } else {
        _append('cd: ${out.isEmpty ? 'no such directory' : out}');
      }
      _onChange();
    }

    _outputSub = exec.output.listen(
      (l) => buf.writeln(l),
      onDone: () {
        streamDone = true;
        finish();
      },
      onError: (Object _) {},
    );
    exec.exitCode
        .then((c) {
          code = c;
          finish();
        })
        .catchError((Object e) {
          streamDone = true;
          code = -1;
          _append('cd: $e');
          finish();
        });
  }

  /// Single-quotes [s] for safe POSIX shell interpolation.
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

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
