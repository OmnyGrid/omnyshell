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

    final text = file.readAsStringSync();
    if (text.trim().isEmpty) return empty;

    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw FormatException('Invalid YAML in ${file.path}: ${e.message}');
    }
    if (doc == null) return empty;
    if (doc is! Map) {
      throw FormatException('Profile ${file.path} must be a YAML mapping');
    }

    final rawEnv = doc['env'];
    if (rawEnv == null) return empty;
    if (rawEnv is! Map) {
      throw FormatException('"env" in ${file.path} must be a mapping');
    }

    final base = environment ?? Platform.environment;
    final env = <String, String>{};
    for (final entry in rawEnv.entries) {
      final key = '${entry.key}';
      final value = entry.value == null ? '' : '${entry.value}';
      env[key] = _expand(value, base);
    }
    return NodeProfile(env);
  }

  /// Writes the `PATH` entry of [path]'s profile to [pathValue], preserving any
  /// other `env` entries and surrounding comments. Creates the file (and its
  /// parent directory) from a template when it does not yet exist.
  static void writePath(String path, String pathValue) {
    final file = File(path);
    final existing = file.existsSync() ? file.readAsStringSync() : '';

    if (existing.trim().isEmpty) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(_template(pathValue));
      return;
    }

    final doc = loadYaml(existing);
    if (doc is Map && doc['env'] is Map) {
      final editor = YamlEditor(existing)..update(['env', 'PATH'], pathValue);
      file.writeAsStringSync(editor.toString());
    } else if (doc is Map) {
      final editor = YamlEditor(existing)..update(['env'], {'PATH': pathValue});
      file.writeAsStringSync(editor.toString());
    } else {
      // Root is not a mapping (unexpected); replace with a fresh template.
      file.writeAsStringSync(_template(pathValue));
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
