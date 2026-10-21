import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../../domain/backend/pty_spec.dart';
import '../../../domain/backend/shell_backend.dart';
import '../../../domain/backend/shell_request.dart';
import '../../../domain/backend/shell_session.dart';
import '../../../shared/utils/pub_cache_bin.dart';
import '../live_environment.dart';
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
/// - `winpty.dll` / a usable Git bash cannot be found on the session's `PATH`
///   (checked per session, so a Git install added later is picked up), or
/// - a spawn fails — after the first such failure that Git install's winpty is
///   not used again by the process, and its sessions use the pipe fallback.
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

  /// When set, supplies the extra environment per session instead of
  /// [baseEnvironment]; see `ProcessShellBackend.baseEnvironmentFor`.
  final Map<String, String> Function(Map<String, String> inherited)?
  baseEnvironmentFor;

  /// Optional guard; when it returns `false` the session is refused.
  final bool Function(ShellRequest request)? allowCommand;

  /// Backend used for exec sessions and whenever the winpty path is unavailable.
  final ShellBackend fallback;

  /// Optional sink for a one-time warning when the winpty path is disabled.
  final void Function(String message)? onWarning;

  /// Loaded libraries, by `winpty.dll` path.
  final Map<String, WinptyLib> _libs = {};

  /// `winpty.dll` paths whose spawn failed: not tried again this process.
  final Set<String> _failedDlls = {};

  /// Creates a winpty-based PTY backend decorating [fallback].
  WinptyShellBackend({
    required this.fallback,
    String? defaultShell,
    this.workingDirectory,
    this.baseEnvironment = const {},
    this.baseEnvironmentFor,
    this.allowCommand,
    this.onWarning,
  }) : defaultShell = defaultShell ?? resolveDefaultShell() {
    // See `ProcessShellBackend`: the registry baseline at node start.
    primeLiveEnvironment();
  }

  @override
  Future<ShellSession> start(ShellRequest request) async {
    final spec = request.pty;
    if (spec == null || !Platform.isWindows) {
      return fallback.start(request);
    }

    // The system and user variables as the registry holds them now, not as
    // they were when the node started (see `live_environment`), with the
    // profile over them: the environment the session gets.
    final live = liveProcessEnvironment();
    final env = mergeEnvironment([
      live,
      baseEnvironmentFor?.call(live) ?? baseEnvironment,
    ]);
    // Bash and the winpty.dll beside it, resolved per session from that
    // environment's `PATH` (both cached until it changes): a Git install added,
    // moved or removed while the node runs is followed, and the DLL always
    // matches the bash it drives. Without them this session uses pipes.
    final bash = resolveWindowsBash(environment: env);
    final dll = bash == null ? null : _winptyDllFor(bash);
    if (bash == null || dll == null || _failedDlls.contains(dll)) {
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
      return _spawn(request, spec, env, bash, dll);
    } on Object catch (e) {
      // Stop using this winpty for the rest of the process and fall back so the
      // session still works (with env-var geometry) instead of being rejected.
      _failedDlls.add(dll);
      onWarning?.call(
        'winpty PTY backend unavailable, using pipe fallback: $e',
      );
      return fallback.start(request);
    }
  }

  ShellSession _spawn(
    ShellRequest request,
    PtySpec spec,
    Map<String, String> base,
    String bash,
    String dll,
  ) {
    final lib = _libs[dll] ??= WinptyLib(dll);

    // Run bash prompt-free and non-echoing, reading its command stream from the
    // pty's /dev/stdin — mirroring ScriptPtyShellBackend. The seeding shell sets
    // `stty -echo` then `exec`s the reader; the client's PosixShellDialect
    // re-enables echo per command (which now works because winpty is a real tty).
    final inner = 'stty -echo 2>/dev/null; exec bash /dev/stdin';
    final cmdline = '"$bash" -c "$inner"';

    // Client's choice, then the node's, then the user's home (a profile `HOME`
    // first) — already resolved to a path winpty can chdir into. See
    // `resolveStartDirectory`.
    final cwd =
        resolveStartDirectory(
          requested: request.cwd,
          configured: workingDirectory,
          environment: base,
        ) ??
        '';

    // `withPubCacheBin` puts the pub cache `bin` directory on `PATH` when the
    // inherited environment and the node profile both leave it off, so a
    // `dart pub global activate`-installed CLI is runnable in the session.
    // Merged case-insensitively, so the block never carries both `Path` and
    // `PATH` (the first would shadow the other).
    final merged = mergeEnvironment([
      base,
      {'TERM': spec.term, 'COLUMNS': '${spec.cols}', 'LINES': '${spec.rows}'},
      request.env,
    ]);
    final env = mergeEnvironment([
      withPubCacheBin(merged, processEnvironment: merged),
    ]);

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

  /// The absolute path to the `winpty.dll` of the Git install [bash] belongs
  /// to, or `null` when it (or its required `winpty-agent.exe` sibling) is not
  /// there. Two file checks, so not cached: the install can change.
  static String? _winptyDllFor(String bash) {
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
}
