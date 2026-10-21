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
library;

import 'dart:collection';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The node's environment, with the system and user variables refreshed from
/// the registry on Windows (see the library docs). Falls back to the node's own
/// environment when the registry cannot be read.
///
/// On Windows the result looks names up case-insensitively, like
/// [Platform.environment] does there, and a name both have keeps the node's
/// spelling (e.g. `Path`), so an overlay onto the inherited environment
/// replaces it rather than adding a second `PATH`.
Map<String, String> liveProcessEnvironment() {
  final base = Platform.environment;
  if (!Platform.isWindows) return base;
  final fresh = windowsRegistryEnvironment();
  return fresh == null
      ? base
      : overlayEnvironment(base, fresh, caseInsensitive: true);
}

/// The variables of [live] whose values differ from (or are absent in) the
/// node's own environment, for a backend that spawns with
/// `includeParentEnvironment: true` and so only needs to send what changed.
/// Empty off Windows, where [liveProcessEnvironment] is the node's environment.
Map<String, String> refreshedVariables(Map<String, String> live) {
  if (identical(live, Platform.environment)) return const {};
  final base = Platform.environment;
  return {
    for (final MapEntry(:key, :value) in live.entries)
      if (base[key] != value) key: value,
  };
}

/// [base] with every variable of [fresh] applied over it.
///
/// With [caseInsensitive] (Windows, whose variable names are), names match
/// regardless of case, a name in both keeps [base]'s spelling, and the result
/// looks names up case-insensitively.
Map<String, String> overlayEnvironment(
  Map<String, String> base,
  Map<String, String> fresh, {
  required bool caseInsensitive,
}) {
  final out = caseInsensitive
      ? LinkedHashMap<String, String>(
          equals: (a, b) => a.toUpperCase() == b.toUpperCase(),
          hashCode: (k) => k.toUpperCase().hashCode,
        )
      : <String, String>{};
  // Assigning to a name already present keeps its original spelling.
  out
    ..addAll(base)
    ..addAll(fresh);
  return out;
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
