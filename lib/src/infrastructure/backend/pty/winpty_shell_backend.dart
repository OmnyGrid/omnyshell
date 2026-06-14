import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../../domain/backend/pty_spec.dart';
import '../../../domain/backend/shell_backend.dart';
import '../../../domain/backend/shell_request.dart';
import '../../../domain/backend/shell_session.dart';
import '../../../shared/utils/omnyshell_home.dart';
import '../shell_invocation.dart';
import 'winpty_ffi.dart';
import 'winpty_shell_session.dart';

/// A [ShellBackend] that runs interactive shells on a real Windows
/// pseudo-console allocated through `libwinpty` (`winpty.dll`, bundled with Git
/// for Windows) via `dart:ffi`.
///
/// It is the Windows counterpart of [`ScriptPtyShellBackend`], which is
/// POSIX-only. Like that backend it decorates a [fallback] (the pipe-based
/// `ProcessShellBackend`) and delegates to it when:
///
/// - the request carries no `PtySpec` (e.g. `exec` mode), or
/// - the platform is not Windows, or
/// - `winpty.dll` / a usable Git bash cannot be found, or
/// - a spawn fails — after the first such failure the winpty path is disabled
///   for the process and every session uses the pipe fallback.
///
/// The winpty CLI is deliberately **not** used: from pipe-backed stdio it derives
/// geometry via `ioctl(STDIN, TIOCGWINSZ)`, gets 0×0 and asserts before the child
/// starts. Calling the library directly with an explicit initial size avoids it.
class WinptyShellBackend implements ShellBackend {
  /// The interactive shell (bash) winpty wraps; resolved on Windows.
  final String defaultShell;

  /// Working directory applied when a request does not specify one.
  final String? workingDirectory;

  /// Extra environment overlaid on the inherited environment for every session.
  final Map<String, String> baseEnvironment;

  /// Optional guard; when it returns `false` the session is refused.
  final bool Function(ShellRequest request)? allowCommand;

  /// Backend used for exec sessions and whenever the winpty path is unavailable.
  final ShellBackend fallback;

  /// Optional sink for a one-time warning when the winpty path is disabled.
  final void Function(String message)? onWarning;

  bool _winptyUsable =
      Platform.isWindows &&
      _winptyDll() != null &&
      resolveWindowsBash() != null;

  WinptyLib? _lib;

  /// Creates a winpty-based PTY backend decorating [fallback].
  WinptyShellBackend({
    required this.fallback,
    String? defaultShell,
    this.workingDirectory,
    this.baseEnvironment = const {},
    this.allowCommand,
    this.onWarning,
  }) : defaultShell = defaultShell ?? resolveDefaultShell();

  @override
  Future<ShellSession> start(ShellRequest request) async {
    final spec = request.pty;
    if (spec == null || !_winptyUsable) {
      return fallback.start(request);
    }

    if (allowCommand != null && !allowCommand!(request)) {
      throw ProcessException(
        request.command ?? defaultShell,
        request.args,
        'Command not permitted by node policy',
      );
    }

    try {
      return _spawn(request, spec);
    } on Object catch (e) {
      // Disable the winpty path for the rest of the process and fall back so the
      // session still works (with env-var geometry) instead of being rejected.
      _winptyUsable = false;
      onWarning?.call(
        'winpty PTY backend unavailable, using pipe fallback: $e',
      );
      return fallback.start(request);
    }
  }

  ShellSession _spawn(ShellRequest request, PtySpec spec) {
    final lib = _lib ??= WinptyLib(_winptyDll()!);
    final bash = resolveWindowsBash()!;

    // Run bash prompt-free and non-echoing, reading its command stream from the
    // pty's /dev/stdin — mirroring ScriptPtyShellBackend. The seeding shell sets
    // `stty -echo` then `exec`s the reader; the client's PosixShellDialect
    // re-enables echo per command (which now works because winpty is a real tty).
    final inner = 'stty -echo 2>/dev/null; exec bash /dev/stdin';
    final cmdline = '"$bash" -c "$inner"';

    // Resolve the working directory to a Windows path winpty can chdir into.
    var cwd = expandUserHome(request.cwd ?? workingDirectory ?? '');
    if (cwd.startsWith('/')) cwd = windowsPathFromMsys(cwd);

    final env = <String, String>{
      ...Platform.environment,
      ...baseEnvironment,
      'TERM': spec.term,
      'COLUMNS': '${spec.cols}',
      'LINES': '${spec.rows}',
      ...request.env,
    };

    final appnamePtr = bash.toNativeUtf16();
    final cmdlinePtr = cmdline.toNativeUtf16();
    final cwdPtr = cwd.isEmpty ? nullptr : cwd.toNativeUtf16();
    final envPtr = buildEnvironmentBlock(env);
    final errPtr = calloc<Pointer<Void>>();
    final procHandle = calloc<Pointer<Void>>();
    final createErr = calloc<Uint32>();

    Pointer<Void> cfg = nullptr;
    Pointer<Void> scfg = nullptr;
    Pointer<Void> wp = nullptr;
    try {
      cfg = lib.configNew(0, errPtr);
      if (cfg.address == 0) {
        throw StateError('winpty_config_new failed: ${lib.drainError(errPtr)}');
      }
      lib.configSetInitialSize(cfg, spec.cols, spec.rows);

      wp = lib.open(cfg, errPtr);
      if (wp.address == 0) {
        throw StateError('winpty_open failed: ${lib.drainError(errPtr)}');
      }

      final coninName = lib.coninName(wp).toDartString();
      final conoutName = lib.conoutName(wp).toDartString();

      scfg = lib.spawnConfigNew(
        kWinptySpawnFlagAutoShutdown,
        appnamePtr,
        cmdlinePtr,
        cwdPtr,
        envPtr,
        errPtr,
      );
      if (scfg.address == 0) {
        throw StateError(
          'winpty_spawn_config_new failed: ${lib.drainError(errPtr)}',
        );
      }

      final ok = lib.spawn(wp, scfg, procHandle, nullptr, createErr, errPtr);
      if (ok == 0) {
        final detail = lib.drainError(errPtr);
        throw StateError(
          'winpty_spawn failed (CreateProcess error ${createErr.value}): $detail',
        );
      }

      final session = WinptyShellSession(
        winpty: lib,
        winptyPtr: wp,
        childHandle: procHandle.value,
        coninName: coninName,
        conoutName: conoutName,
      );
      wp = nullptr; // ownership transferred to the session
      return session;
    } finally {
      if (cfg.address != 0) lib.configFree(cfg);
      if (scfg.address != 0) lib.spawnConfigFree(scfg);
      if (wp.address != 0) lib.free(wp); // only if we threw after open
      calloc.free(appnamePtr);
      calloc.free(cmdlinePtr);
      if (cwdPtr != nullptr) calloc.free(cwdPtr);
      if (envPtr != nullptr) calloc.free(envPtr);
      calloc.free(errPtr);
      calloc.free(procHandle);
      calloc.free(createErr);
    }
  }

  /// The absolute path to `winpty.dll`, or `null` when it (or its required
  /// `winpty-agent.exe` sibling) cannot be found relative to the Git bash. The
  /// result is cached for the process.
  static String? _winptyDll() {
    if (_resolvedDll != _unresolved) return _resolvedDll;
    return _resolvedDll = _probeWinptyDll();
  }

  static String? _probeWinptyDll() {
    final bash = resolveWindowsBash();
    if (bash == null) return null;
    final bashDir = p.dirname(bash);
    final candidates = <String>{
      // …\Git\usr\bin\bash.exe → sibling winpty.dll.
      p.join(bashDir, 'winpty.dll'),
      // …\Git\bin\bash.exe → …\Git\usr\bin\winpty.dll.
      p.normalize(p.join(bashDir, '..', 'usr', 'bin', 'winpty.dll')),
    };
    for (final dll in candidates) {
      final agent = p.join(p.dirname(dll), 'winpty-agent.exe');
      if (File(dll).existsSync() && File(agent).existsSync()) return dll;
    }
    return null;
  }

  static const String _unresolved = 'unresolved';
  static String? _resolvedDll = _unresolved;
}
