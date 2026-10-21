import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../shared/utils/omnyshell_home.dart';

/// A node's environment profile, persisted at `~/.omnyshell/profile.yaml` and
/// applied as the `baseEnvironment` of every shell/exec session the node serves.
///
/// Sessions run the node's shell **non-interactively**, so no rc file
/// (`.zshrc`, `.bashrc`, ...) is sourced; this profile is how a node carries a
/// prepared `PATH` (and any other env the operator adds) into every session.
///
/// File shape:
///
/// ```yaml
/// env:
///   PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
///   EDITOR: vim
/// ```
///
/// Values may reference other variables with `${VAR}`/`$VAR`; these are expanded
/// at [load] time against the node's own environment, because the resulting
/// strings are passed verbatim to `Process.start` (no shell interprets them).
class NodeProfile {
  /// Environment variables overlaid on every session, fully expanded.
  final Map<String, String> env;

  const NodeProfile(this.env);

  /// An empty profile (no overrides).
  static const NodeProfile empty = NodeProfile(<String, String>{});

  /// The default profile path, `~/.omnyshell/profile.yaml` (honoring
  /// `OMNYSHELL_HOME`/`HOME`). [home] overrides the base directory in tests.
  static String defaultPath({String? home}) =>
      omnyshellPath(['profile.yaml'], home: home);

  /// Loads the profile from [path] (defaults to [defaultPath]).
  ///
  /// A missing file yields [empty]. Throws [FormatException] when the file is
  /// not valid YAML or `env` is present but not a mapping. [environment]
  /// overrides the variables used for `${VAR}` expansion (tests).
  static NodeProfile load({
    String? path,
    String? home,
    Map<String, String>? environment,
  }) {
    final file = File(path ?? defaultPath(home: home));
    if (!file.existsSync()) return empty;
    final raw = _parse(file.readAsStringSync(), file.path);
    return NodeProfile(expand(raw, environment ?? Platform.environment));
  }

  /// The unexpanded `env` entries of a profile's [text] ([path] names it in
  /// errors). Throws [FormatException] like [load].
  static Map<String, String> _parse(String text, String path) {
    if (text.trim().isEmpty) return const {};

    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw FormatException('Invalid YAML in $path: ${e.message}');
    }
    if (doc == null) return const {};
    if (doc is! Map) {
      throw FormatException('Profile $path must be a YAML mapping');
    }

    final rawEnv = doc['env'];
    if (rawEnv == null) return const {};
    if (rawEnv is! Map) {
      throw FormatException('"env" in $path must be a mapping');
    }
    return {
      for (final entry in rawEnv.entries)
        '${entry.key}': entry.value == null ? '' : '${entry.value}',
    };
  }

  /// [raw] with each value's `${VAR}`/`$VAR` references expanded against
  /// [environment].
  static Map<String, String> expand(
    Map<String, String> raw,
    Map<String, String> environment,
  ) => {
    for (final MapEntry(:key, :value) in raw.entries)
      key: _expand(value, environment),
  };

  /// Writes the `PATH` entry of [path]'s profile to [pathValue], preserving any
  /// other `env` entries and surrounding comments. Creates the file (and its
  /// parent directory) from a template when it does not yet exist.
  static void writePath(String path, String pathValue) {
    final file = File(path);
    final existing = file.existsSync() ? file.readAsStringSync() : '';

    if (existing.trim().isEmpty) {
      file.parent.createSync(recursive: true);
      _writeAtomically(file, _template(pathValue));
      return;
    }

    final doc = loadYaml(existing);
    if (doc is Map && doc['env'] is Map) {
      final editor = YamlEditor(existing)..update(['env', 'PATH'], pathValue);
      _writeAtomically(file, editor.toString());
    } else if (doc is Map) {
      final editor = YamlEditor(existing)..update(['env'], {'PATH': pathValue});
      _writeAtomically(file, editor.toString());
    } else {
      // Root is not a mapping (unexpected); replace with a fresh template.
      _writeAtomically(file, _template(pathValue));
    }
  }

  /// Replaces [file]'s content with [text] in one step: written beside it,
  /// then renamed over it. A running node re-reads the profile per session
  /// ([LiveNodeProfile]), and a plain write (truncate, then write) could be
  /// read half-done — empty, or with a cut-off `PATH` that still parses.
  ///
  /// A symlinked profile (e.g. into a dotfiles repo) is written through: the
  /// link's target is replaced, the link kept. The target's permissions carry
  /// over to the new file, so a `chmod 600` profile holding secrets under
  /// `env:` does not come back world-readable.
  static void _writeAtomically(File file, String text) {
    final target = file.existsSync()
        ? File(file.resolveSymbolicLinksSync())
        : file;
    final mode = target.existsSync() ? target.statSync().mode & 0x1ff : null;
    final tmp = File('${target.path}.tmp-$pid');
    try {
      tmp.writeAsStringSync(text, flush: true);
      if (mode != null && !Platform.isWindows) {
        final r = Process.runSync('chmod', [mode.toRadixString(8), tmp.path]);
        if (r.exitCode != 0) {
          throw FileSystemException('chmod failed: ${r.stderr}', tmp.path);
        }
      }
      tmp.renameSync(target.path);
    } on Object {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }

  /// Expands `${VAR}` and `$VAR` references in [value] against [env]; unknown
  /// variables expand to the empty string.
  static String _expand(String value, Map<String, String> env) =>
      value.replaceAllMapped(_varRef, (m) {
        final name = m.group(1) ?? m.group(2)!;
        return env[name] ?? '';
      });

  static final RegExp _varRef = RegExp(
    r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)',
  );

  static String _template(String pathValue) =>
      '# ~/.omnyshell/profile.yaml — managed by `omnyshell node`\n'
      '# Environment applied to every shell/exec session on this node.\n'
      '# Add your own variables under `env:`; they are preserved on PATH sync.\n'
      'env:\n'
      '  PATH: ${_yamlScalar(pathValue)}\n';

  /// Double-quotes [s] as a YAML scalar, escaping `\` and `"`.
  static String _yamlScalar(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// A node's profile file, followed while the node runs, so an edit (by hand, or
/// by `omnyshell node profile sync` from another process) applies to the next
/// session without restarting the node.
///
/// [envFor] re-reads the file on every call. It is a few hundred bytes, read
/// once per session, and comparing its text (not its modification time, whose
/// resolution can hide two quick edits) decides whether to parse it again.
///
/// `${VAR}` references are expanded per call against the environment the
/// session will get, so `PATH: "C:\tools;${PATH}"` follows a `PATH` that has
/// changed since (see `liveProcessEnvironment`) instead of freezing it.
class LiveNodeProfile {
  /// The profile file followed.
  final String path;

  /// Told when an edited profile cannot be parsed or read; the last good one
  /// stays in effect until the file is fixed. Called once per distinct broken
  /// text, and once per spell of the file being unreadable.
  final void Function(String message)? onWarning;

  String? _text;
  Map<String, String> _raw = const {};
  String? _rejected;
  bool _unreadable = false;

  /// Follows the profile at [path] (default: [NodeProfile.defaultPath]).
  ///
  /// Reads it now and throws, as [NodeProfile.load] does, when it is invalid
  /// ([FormatException]) or exists but cannot be read (permissions, invalid
  /// UTF-8: [FileSystemException]): a node should not start on a broken
  /// profile, nor quietly without one.
  LiveNodeProfile({String? path, this.onWarning})
    : path = path ?? NodeProfile.defaultPath() {
    final file = File(this.path);
    final text = file.existsSync() ? file.readAsStringSync() : null;
    _raw = text == null ? const {} : NodeProfile._parse(text, this.path);
    _text = text;
  }

  /// The profile's variables for a session starting now, expanded against
  /// [environment] (default: this process's).
  ///
  /// A missing file means an empty profile, as for [NodeProfile.load].
  Map<String, String> envFor([Map<String, String>? environment]) {
    _refresh();
    return NodeProfile.expand(_raw, environment ?? Platform.environment);
  }

  void _refresh() {
    final (:error, :text) = _readNow();
    // Unreadable (a Windows sharing violation while another process writes
    // it, permissions, invalid UTF-8): keep what is in effect rather than take
    // it as gone, and say so once until it is readable again.
    if (error != null) {
      if (!_unreadable) {
        _unreadable = true;
        onWarning?.call(
          'cannot read $path ($error); keeping the previous profile',
        );
      }
      return;
    }
    _unreadable = false;
    if (text == _text) {
      // Back to the text in effect: a later breakage, even the same one,
      // deserves a fresh warning.
      _rejected = null;
      return;
    }
    try {
      _raw = text == null ? const {} : NodeProfile._parse(text, path);
      _text = text;
      _rejected = null;
    } on FormatException catch (e) {
      if (_rejected != text) {
        _rejected = text;
        onWarning?.call('${e.message}; keeping the previous profile');
      }
    }
  }

  /// The file's [text] (`null` when there is no file), or the [error] that
  /// kept an existing file from being read.
  ({String? error, String? text}) _readNow() {
    final file = File(path);
    try {
      return (error: null, text: file.readAsStringSync());
    } on FileSystemException catch (e) {
      return file.existsSync()
          ? (error: e.osError?.message ?? e.message, text: null)
          : (error: null, text: null);
    }
  }
}
