import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../domain/backend/shell_family.dart';
import '../../../domain/backend/shell_session.dart';

/// A [ShellSession] backed by a real pseudo-terminal allocated by the system
/// `script(1)` utility, which runs as an ordinary child [Process].
///
/// Unlike the FFI-based `PtyShellSession` (which loads the `portable_pty` native
/// library), all PTY ownership — `forkpty`, the controlling terminal and signal
/// handling — lives inside the `script` process. The node only does pipe I/O and
/// reaps a normal child, so this backend cannot trigger the native `SIGCHLD`
/// crash that affects `portable_pty`.
///
/// `script` bridges the child's tty to its own stdin/stdout, so:
/// - [stdout] is the merged terminal output (the pty folds stderr into stdout);
/// - [writeStdin] feeds the child's tty input;
/// - [exitCode] is the child's exit status, surfaced by `script`.
///
/// `script` launched from pipes leaves the node no pty fd of its own, so [resize]
/// can't follow a `SIGWINCH` the usual way. Instead the backend has the wrapper
/// record the child's controlling-tty path (`tty` → [_ttyFile]) at spawn, and
/// [resize] sets the window size directly on that PTS with `stty` — which fires
/// `TIOCSWINSZ`, so the kernel delivers `SIGWINCH` to the foreground program and
/// it reflows. No FFI, no native library. The initial geometry is still seeded
/// via `stty rows/cols` before `exec`.
class ScriptPtyShellSession implements ShellSession {
  final Process _process;

  /// File the wrapper wrote the child's controlling-tty path into; `null`
  /// disables live resize (the prior no-op behaviour, e.g. in tests).
  final String? _ttyFile;

  /// Temp dir owning [_ttyFile], removed on teardown.
  final Directory? _ttyDir;

  /// The PTS path read from [_ttyFile], cached after the first non-empty read.
  String? _ttyPathCache;

  /// The latest size requested before the PTS path was known, applied as soon
  /// as it is (see [resize]).
  ({int cols, int rows})? _pendingSize;

  /// Polls for the PTS path while a [_pendingSize] waits.
  Timer? _pendingTimer;

  /// How often, and for how long, a resize requested before the wrapper has
  /// recorded the PTS path keeps retrying.
  static const Duration _pendingPoll = Duration(milliseconds: 25);
  static const Duration _pendingTimeout = Duration(seconds: 5);

  bool _exited = false;

  /// Wraps an already-started `script` [Process]. [ttyFile] (and its owning
  /// [ttyDir]) carry the child PTS path for [resize].
  ScriptPtyShellSession(this._process, {String? ttyFile, Directory? ttyDir})
    : _ttyFile = ttyFile,
      _ttyDir = ttyDir {
    // Remove the temp dir whether the session is killed or the child exits.
    unawaited(
      _process.exitCode
          .then((_) {
            _exited = true;
            _cancelPending();
            _cleanupTtyDir();
          })
          .catchError((_) {}),
    );
  }

  // The `script`-based PTY backend is POSIX-only (disabled on Windows), so the
  // shell it wraps always speaks the POSIX dialect.
  @override
  ShellFamily get shellFamily => ShellFamily.posix;

  @override
  int? get pid => _process.pid;

  @override
  Stream<Uint8List> get stdout =>
      _process.stdout.map((chunk) => Uint8List.fromList(chunk));

  // A PTY merges the child's stderr into the single master stream, so there is
  // no separate stderr channel; an empty (immediately-done) stream keeps the
  // node's stdout/stderr drain logic happy.
  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void writeStdin(List<int> data) {
    try {
      _process.stdin.add(data);
    } on Object {
      // The child may have exited and `script` closed its stdin.
    }
  }

  @override
  Future<void> closeStdin() async {
    // A PTY has no half-close; deliver the terminal EOF character (Ctrl-D) so
    // the line discipline signals end-of-input to the foreground program.
    try {
      _process.stdin.add(const [0x04]);
    } on Object {
      // Ignore: child already gone.
    }
  }

  /// Whether the PTS path is known, so a [resize] now applies immediately.
  bool get canResizeNow => _ttyPath() != null;

  /// Whether a [resize] is waiting for the PTS path to become known.
  bool get hasPendingResize => _pendingSize != null;

  /// Sets the child terminal's window size.
  ///
  /// The wrapper records the PTS path a moment after `script` starts. A resize
  /// requested before that — e.g. a client sending its size right after the
  /// session opens — is kept and applied as soon as the path appears (polled
  /// every 25ms for up to 5s, until the child exits). Only the latest pending
  /// size is applied. Without a tty file live resize is disabled (a no-op).
  @override
  void resize({required int cols, required int rows}) {
    if (_ttyFile == null || _exited) return;
    final path = _ttyPath();
    if (path != null) {
      _cancelPending();
      _applySize(path, cols: cols, rows: rows);
      return;
    }
    _pendingSize = (cols: cols, rows: rows);
    if (_pendingTimer != null) return;
    final deadline = DateTime.now().add(_pendingTimeout);
    _pendingTimer = Timer.periodic(_pendingPoll, (_) {
      final size = _pendingSize;
      final ready = _ttyPath();
      if (size == null || _exited) {
        _cancelPending();
      } else if (ready != null) {
        _cancelPending();
        _applySize(ready, cols: size.cols, rows: size.rows);
      } else if (DateTime.now().isAfter(deadline)) {
        _cancelPending();
      }
    });
  }

  void _cancelPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingSize = null;
  }

  static void _applySize(String path, {required int cols, required int rows}) {
    // `-F` (GNU/util-linux) vs `-f` (BSD/macOS) selects the device to operate on.
    // Setting the size triggers TIOCSWINSZ → SIGWINCH to the foreground program.
    final flag = Platform.isLinux ? '-F' : '-f';
    try {
      Process.runSync('stty', [flag, path, 'rows', '$rows', 'cols', '$cols']);
    } on Object {
      // Best-effort: a transient stty failure must never break the session.
    }
  }

  /// The child's controlling-tty (PTS) path recorded at spawn, cached after the
  /// first non-empty read. `null` until the wrapper has written it, or when no
  /// [_ttyFile] was provided.
  String? _ttyPath() {
    final cached = _ttyPathCache;
    if (cached != null) return cached;
    final file = _ttyFile;
    if (file == null) return null;
    try {
      final f = File(file);
      if (!f.existsSync()) return null;
      final path = f.readAsStringSync().trim();
      return path.isEmpty ? null : (_ttyPathCache = path);
    } on Object {
      return null;
    }
  }

  void _cleanupTtyDir() {
    try {
      _ttyDir?.deleteSync(recursive: true);
    } on Object {
      // Best-effort temp cleanup.
    }
  }

  @override
  void sendSignal(String signal) {
    // Interactive signals are delivered the terminal-native way: writing the
    // control character lets the pty line discipline raise the signal for the
    // foreground process group (honouring whatever mode the program set).
    final control = _controlChar(signal);
    if (control != null) {
      writeStdin([control]);
      return;
    }
    // Process-wide signals (TERM/KILL/HUP) go to `script`, which relays the
    // hangup to the child when its master closes.
    final sig = _processSignal(signal);
    if (sig != null) {
      try {
        _process.kill(sig);
      } on Object {
        // Ignore: child already gone.
      }
    }
  }

  @override
  Future<void> kill() async {
    try {
      _process.kill(ProcessSignal.sigkill);
    } on Object {
      // Ignore.
    }
    try {
      await _process.stdin.close();
    } on Object {
      // Ignore: stdin already closed.
    }
  }

  /// The control byte that the line discipline turns into a signal, or `null`
  /// for signals without a terminal control character.
  static int? _controlChar(String name) {
    switch (name.toUpperCase()) {
      case 'SIGINT':
      case 'INT':
        return 0x03; // Ctrl-C
      case 'SIGQUIT':
      case 'QUIT':
        return 0x1c; // Ctrl-\
      case 'SIGTSTP':
      case 'TSTP':
        return 0x1a; // Ctrl-Z
      default:
        return null;
    }
  }

  static ProcessSignal? _processSignal(String name) {
    switch (name.toUpperCase()) {
      case 'SIGTERM':
      case 'TERM':
        return ProcessSignal.sigterm;
      case 'SIGKILL':
      case 'KILL':
        return ProcessSignal.sigkill;
      case 'SIGHUP':
      case 'HUP':
        return ProcessSignal.sighup;
      default:
        return null;
    }
  }
}
