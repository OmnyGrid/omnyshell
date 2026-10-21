/// The environment a session started *now* should inherit.
///
/// A process's environment is a snapshot taken when it starts, and a node runs
/// for a long time (as a service, for days). On Windows, environment variables
/// are edited in the registry (System Properties, `setx`, installers adding
/// themselves to `PATH`), and a running process never sees those edits. A node
/// that handed every session its own snapshot would serve a `PATH` that was
/// current when the node started — so a tool installed afterwards would be
/// "not recognized" in every new session until the node was restarted.
///
/// [liveProcessEnvironment] therefore rebuilds the system and user variables
/// from the registry for each session, the way Explorer does for a newly
/// launched program, via `CreateEnvironmentBlock`. Elsewhere it is the node's
/// own environment: on POSIX the equivalent sources are shell rc files, which
/// the node profile captures (see `NodeProfile`).
///
/// What the node's *launcher* set is kept, though: a node (or `omnyshell
/// local`) started from a developer prompt, a venv, or a CI step carries
/// variables and `PATH` entries that are in no registry. Telling them apart
/// takes the registry as it was when the node started (primed by the backends'
/// constructors, see [primeLiveEnvironment]) — see [reconcileEnvironment].
library;

import 'dart:collection';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// An empty environment map that, on Windows, matches names regardless of case
/// (as Windows does, and [Platform.environment] there) and keeps the first
/// spelling a name was added with. Merging maps through it never yields both
/// `Path` and `PATH`, which a child process would see as two variables, the
/// first one shadowing the other.
Map<String, String> newEnvironmentMap() => Platform.isWindows
    ? LinkedHashMap<String, String>(
        equals: (a, b) => a.toUpperCase() == b.toUpperCase(),
        hashCode: (k) => k.toUpperCase().hashCode,
      )
    : <String, String>{};

/// [layers] merged in order, later values winning, in a [newEnvironmentMap].
Map<String, String> mergeEnvironment(Iterable<Map<String, String>> layers) {
  final out = newEnvironmentMap();
  for (final layer in layers) {
    out.addAll(layer);
  }
  return out;
}

bool _primed = false;
Map<String, String>? _startupRegistry;

/// Records the registry environment as it is now, as the baseline that
/// [liveProcessEnvironment] compares this process's own environment against
/// (see [reconcileEnvironment]). Idempotent; the session backends call it when
/// constructed, so the baseline is the registry at node start. Without it, the
/// first [liveProcessEnvironment] call takes the baseline.
///
/// A failed read is not final: the next call tries again, so one transient
/// failure at start does not turn the refresh off for the node's lifetime.
void primeLiveEnvironment() {
  if (_primed || !Platform.isWindows) return;
  _startupRegistry = windowsRegistryEnvironment();
  _primed = _startupRegistry != null;
}

/// The node's environment, with the system and user variables refreshed from
/// the registry on Windows (see the library docs and [reconcileEnvironment]).
/// Falls back to the node's own environment when the registry cannot be read.
/// On Windows the result looks names up case-insensitively.
Map<String, String> liveProcessEnvironment() {
  final own = Platform.environment;
  if (!Platform.isWindows) return own;
  primeLiveEnvironment();
  final startup = _startupRegistry;
  final now = windowsRegistryEnvironment();
  if (startup == null || now == null) return own;
  return reconcileEnvironment(
    own: own,
    startupRegistry: startup,
    registry: now,
  );
}

/// The environment a session should inherit, from this process's [own]
/// environment, the registry environment when the process started
/// ([startupRegistry]) and the registry environment now ([registry]):
///
/// - A variable whose [own] value is what the registry held at start (both
///   absent included) was inherited from it, so it follows the registry:
///   updated, added, or removed when the registry removed it.
/// - A variable whose [own] value differs was set by whatever launched the
///   process, so it is kept — and one the launcher removed (in the registry
///   at start, absent from [own]) stays removed.
/// - `PATH` mixes both: entries of the [own] `PATH` that the registry `PATH`
///   at start lacked were added by the launcher; they stay, ahead of the
///   registry's current `PATH` (launchers prepend: venvs, developer prompts).
///   Entries the launcher dropped from it stay dropped.
///
/// Names match case-insensitively (Windows); the result is a
/// [newEnvironmentMap].
Map<String, String> reconcileEnvironment({
  required Map<String, String> own,
  required Map<String, String> startupRegistry,
  required Map<String, String> registry,
}) {
  final start = mergeEnvironment([startupRegistry]);
  final current = mergeEnvironment([registry]);
  final out = mergeEnvironment([own]);
  for (final MapEntry(key: name, value: then) in start.entries) {
    if (!current.containsKey(name) && out[name] == then) out.remove(name);
  }
  for (final MapEntry(key: name, value: now) in current.entries) {
    final mine = out[name];
    final then = start[name];
    if (name.toUpperCase() == 'PATH' && mine != null) {
      final ownEntries = _entrySet(mine);
      final startEntries = _entrySet(then);
      out[name] = _joinPath([
        ..._pathEntries(
          mine,
        ).where((e) => !startEntries.contains(_normalizeEntry(e))),
        ..._pathEntries(now).where((e) {
          final n = _normalizeEntry(e);
          return ownEntries.contains(n) || !startEntries.contains(n);
        }),
      ]);
    } else if (mine == then) {
      out[name] = now;
    }
  }
  return out;
}

List<String> _pathEntries(String? path) =>
    (path ?? '').split(';').where((e) => e.trim().isNotEmpty).toList();

String _normalizeEntry(String e) =>
    e.trim().replaceAll(RegExp(r'[\\/]+$'), '').toUpperCase();

Set<String> _entrySet(String? path) => {
  for (final e in _pathEntries(path)) _normalizeEntry(e),
};

/// [entries] joined with `;`, keeping the first of any duplicates.
String _joinPath(List<String> entries) {
  final seen = <String>{};
  return entries.where((e) => seen.add(_normalizeEntry(e))).join(';');
}

/// The environment Windows builds for a new process of this process's user
/// right now — the system variables, then the user's, each `REG_EXPAND_SZ`
/// value expanded and the user `Path` appended to the system one — without
/// inheriting anything from this process. `null` off Windows or when it cannot
/// be built.
Map<String, String>? windowsRegistryEnvironment() {
  if (!Platform.isWindows) return null;
  try {
    return _WinEnv.instance.build();
  } on Object {
    return null;
  }
}

/// Parses a Windows environment block: `NAME=value` entries, each ended by a
/// NUL, the block ended by an empty entry. Entries whose name starts with `=`
/// (the hidden per-drive working directories, `=C:=C:\…`) are skipped.
Map<String, String> parseEnvironmentBlock(List<int> units) {
  final env = <String, String>{};
  var start = 0;
  for (var i = 0; i < units.length; i++) {
    if (units[i] != 0) continue;
    if (i == start) break; // the empty entry that ends the block
    final entry = String.fromCharCodes(units, start, i);
    start = i + 1;
    final eq = entry.indexOf('=', 1);
    if (eq <= 0 || entry.startsWith('=')) continue;
    env[entry.substring(0, eq)] = entry.substring(eq + 1);
  }
  return env;
}

// --- Win32 bindings ---------------------------------------------------------

/// `TOKEN_QUERY | TOKEN_DUPLICATE`: what `CreateEnvironmentBlock` needs on a
/// primary token.
const int _tokenAccess = 0x0008 | 0x0002;

typedef _GetCurrentProcessC = Pointer<Void> Function();
typedef _OpenProcessTokenC =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>);
typedef _OpenProcessTokenDart =
    int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _HandleFnC = Int32 Function(Pointer<Void>);
typedef _HandleFnDart = int Function(Pointer<Void>);
typedef _CreateEnvironmentBlockC =
    Int32 Function(Pointer<Pointer<Void>>, Pointer<Void>, Int32);
typedef _CreateEnvironmentBlockDart =
    int Function(Pointer<Pointer<Void>>, Pointer<Void>, int);

/// Hand-rolled bindings (no `win32` package), like the winpty ones.
class _WinEnv {
  static final _WinEnv instance = _WinEnv._();

  final Pointer<Void> Function() _getCurrentProcess;
  final _OpenProcessTokenDart _openProcessToken;
  final _HandleFnDart _closeHandle;
  final _CreateEnvironmentBlockDart _createEnvironmentBlock;
  final _HandleFnDart _destroyEnvironmentBlock;

  _WinEnv._()
    : _getCurrentProcess = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_GetCurrentProcessC, Pointer<Void> Function()>(
            'GetCurrentProcess',
          ),
      _openProcessToken = DynamicLibrary.open('advapi32.dll')
          .lookupFunction<_OpenProcessTokenC, _OpenProcessTokenDart>(
            'OpenProcessToken',
          ),
      _closeHandle = DynamicLibrary.open(
        'kernel32.dll',
      ).lookupFunction<_HandleFnC, _HandleFnDart>('CloseHandle'),
      _createEnvironmentBlock = DynamicLibrary.open('userenv.dll')
          .lookupFunction<
            _CreateEnvironmentBlockC,
            _CreateEnvironmentBlockDart
          >('CreateEnvironmentBlock'),
      _destroyEnvironmentBlock = DynamicLibrary.open(
        'userenv.dll',
      ).lookupFunction<_HandleFnC, _HandleFnDart>('DestroyEnvironmentBlock');

  /// The fresh environment of this process's user, or `null` on failure.
  Map<String, String>? build() {
    final token = calloc<Pointer<Void>>();
    final block = calloc<Pointer<Void>>();
    try {
      if (_openProcessToken(_getCurrentProcess(), _tokenAccess, token) == 0) {
        return null;
      }
      try {
        // bInherit = FALSE: only what the registry holds, not this process's
        // (stale) variables.
        if (_createEnvironmentBlock(block, token.value, 0) == 0) return null;
        try {
          return parseEnvironmentBlock(_units(block.value.cast<Uint16>()));
        } finally {
          _destroyEnvironmentBlock(block.value);
        }
      } finally {
        _closeHandle(token.value);
      }
    } finally {
      calloc
        ..free(token)
        ..free(block);
    }
  }

  /// The UTF-16 units of the block at [p], through its terminating empty entry.
  static List<int> _units(Pointer<Uint16> p) {
    var n = 0;
    // Two consecutive NULs end the block (an entry's NUL + the empty entry's).
    while (!(p[n] == 0 && (n == 0 || p[n - 1] == 0))) {
      n++;
    }
    return p.asTypedList(n + 1);
  }
}
