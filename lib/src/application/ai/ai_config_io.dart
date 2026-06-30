import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../shared/utils/omnyshell_home.dart';
import 'agent_mode.dart';
import 'ai_config.dart';

/// A non-secret summary of the resolved AI configuration, used by
/// `omnyshell ai show` to report settings and where each value came from. The
/// API key is never included — only [keySet] and [keyFromEnv].
class AiConfigDescription {
  const AiConfigDescription({
    required this.path,
    required this.fileExists,
    required this.provider,
    required this.providerFromEnv,
    required this.model,
    required this.modelFromEnv,
    required this.modelFromDefault,
    required this.plannerModel,
    required this.plannerFromDefault,
    required this.executorModel,
    required this.explainerModel,
    required this.mode,
    required this.language,
    required this.baseUrl,
    required this.maxSteps,
    required this.keySet,
    required this.keyFromEnv,
    required this.keyEnvVar,
  });

  final String path;
  final bool fileExists;

  /// `null` when no provider is configured anywhere.
  final AiProviderKind? provider;
  final bool providerFromEnv;
  final String? model;
  final bool modelFromEnv;

  /// Whether [model] is the built-in per-provider default (not set by the user
  /// in env or `ai.yaml`).
  final bool modelFromDefault;

  /// Per-phase model overrides; `null` means the phase uses [model].
  final String? plannerModel;

  /// Whether [plannerModel] is the built-in per-provider default (not set by
  /// the user in `ai.yaml`).
  final bool plannerFromDefault;
  final String? executorModel;

  /// The command-explain model override; `null` means it uses [model].
  final String? explainerModel;
  final AgentMode mode;

  /// The agent's reply language (free-form), or `null` when unset.
  final String? language;
  final String? baseUrl;
  final int maxSteps;

  /// Whether an API key is available (env or file).
  final bool keySet;
  final bool keyFromEnv;

  /// The provider's API-key environment variable (e.g. `ANTHROPIC_API_KEY`), or
  /// `null` when no provider is resolved.
  final String? keyEnvVar;
}

/// Loads and persists [AiConfig] from the environment and `~/.omnyshell/ai.yaml`.
///
/// File shape:
/// ```yaml
/// ai:
///   provider: anthropic   # anthropic | openai | gemini
///   model: <model-id>     # shared/default model for both phases
///   plannerModel: <id>    # optional stronger model for planning
///   executorModel: <id>   # optional cheaper model for execution
///   explainerModel: <id>  # optional model for explaining a command (?)
///   apiKey: "..."         # optional if the matching env var is set
///   mode: plan            # default agent mode
///   language: portuguese  # optional reply language (free-form)
///   baseUrl: "..."        # optional API base-URL override
///   maxSteps: 24          # agent loop bound
/// ```
///
/// Resolution: provider/model come from env (`OMNYSHELL_AI_PROVIDER` /
/// `OMNYSHELL_AI_MODEL`) then `ai.yaml`; the API key prefers the provider's env
/// var (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`) and falls back
/// to `ai.yaml`. [load] returns `null` when no usable provider+key can be
/// resolved (the caller then installs a stub `:ai` that prints setup help).
class AiConfigIo {
  AiConfigIo._();

  /// Default *planner* (stronger) model per provider, used only when
  /// `ai.yaml`/env do not specify one. The cheaper base/executor default is
  /// shared with web clients via [defaultModelFor]; the planner default is
  /// CLI-only and kept here. All overridable in `ai.yaml`.
  static const _plannerDefaults = {
    AiProviderKind.anthropic: 'claude-sonnet-4-6',
    AiProviderKind.openai: 'gpt-5.4-mini',
    AiProviderKind.gemini: 'gemini-2.5-flash',
  };

  static const _envKeys = {
    AiProviderKind.anthropic: 'ANTHROPIC_API_KEY',
    AiProviderKind.openai: 'OPENAI_API_KEY',
    AiProviderKind.gemini: 'GEMINI_API_KEY',
  };

  /// The provider's API-key environment variable name.
  static String envVarFor(AiProviderKind provider) => _envKeys[provider]!;

  /// The default `ai.yaml` path (honoring `OMNYSHELL_HOME`/`HOME`).
  static String defaultPath({String? home}) =>
      omnyshellPath(['ai.yaml'], home: home);

  static AiConfig? load({
    String? path,
    String? home,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final yaml = _readYaml(path ?? defaultPath(home: home));

    final provider =
        AiProviderKind.tryParse(env['OMNYSHELL_AI_PROVIDER']) ??
        AiProviderKind.tryParse(yaml['provider'] as String?) ??
        _inferProviderFromEnv(env);
    if (provider == null) return null;

    final apiKey = env[_envKeys[provider]!]?.trim().isNotEmpty == true
        ? env[_envKeys[provider]!]!.trim()
        : (yaml['apiKey'] as String?)?.trim();
    if (apiKey == null || apiKey.isEmpty) return null;

    return AiConfig(
      provider: provider,
      model: _resolveModel(env, yaml, provider),
      apiKey: apiKey,
      plannerModel: _str(yaml['plannerModel']) ?? _plannerDefaults[provider]!,
      executorModel: _str(yaml['executorModel']),
      explainerModel: _str(yaml['explainerModel']),
      baseUrl: _str(yaml['baseUrl']),
      defaultMode:
          AgentMode.tryParse(yaml['mode'] as String?) ?? AgentMode.plan,
      language: _str(yaml['language']),
      maxSteps: _int(yaml['maxSteps']) ?? 24,
    );
  }

  /// Reports the resolved configuration without exposing the API key, for
  /// `omnyshell ai show`.
  static AiConfigDescription describe({
    String? path,
    String? home,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final filePath = path ?? defaultPath(home: home);
    final yaml = _readYaml(filePath);

    final providerFromEnv = AiProviderKind.tryParse(
      env['OMNYSHELL_AI_PROVIDER'],
    );
    final provider =
        providerFromEnv ??
        AiProviderKind.tryParse(yaml['provider'] as String?) ??
        _inferProviderFromEnv(env);

    final modelFromEnv = _str(env['OMNYSHELL_AI_MODEL']) != null;
    // The shared model falls back to the per-provider default only when neither
    // env nor file set it; the planner default kicks in when the file omits it.
    final modelFromDefault =
        provider != null && !modelFromEnv && _str(yaml['model']) == null;
    final plannerFromDefault =
        provider != null && _str(yaml['plannerModel']) == null;
    final keyEnvVar = provider == null ? null : _envKeys[provider];
    final keyFromEnv = keyEnvVar != null && _str(env[keyEnvVar]) != null;
    final keySet = keyFromEnv || _str(yaml['apiKey']) != null;

    return AiConfigDescription(
      path: filePath,
      fileExists: File(filePath).existsSync(),
      provider: provider,
      providerFromEnv: providerFromEnv != null,
      model: provider == null
          ? _str(yaml['model'])
          : _resolveModel(env, yaml, provider),
      modelFromEnv: modelFromEnv,
      modelFromDefault: modelFromDefault,
      plannerModel:
          _str(yaml['plannerModel']) ??
          (provider == null ? null : _plannerDefaults[provider]!),
      plannerFromDefault: plannerFromDefault,
      executorModel: _str(yaml['executorModel']),
      explainerModel: _str(yaml['explainerModel']),
      mode: AgentMode.tryParse(yaml['mode'] as String?) ?? AgentMode.plan,
      language: _str(yaml['language']),
      baseUrl: _str(yaml['baseUrl']),
      maxSteps: _int(yaml['maxSteps']) ?? 24,
      keySet: keySet,
      keyFromEnv: keyFromEnv,
      keyEnvVar: keyEnvVar,
    );
  }

  /// Writes the given fields into `ai.yaml`, updating only the keys provided and
  /// preserving the rest (and surrounding comments). Creates the file and its
  /// parent directory (mode 600/700 on POSIX) when missing.
  ///
  /// A `null` value leaves the key untouched. An **empty-string** value clears
  /// the key — it is removed from the file so resolution falls back to the
  /// default (e.g. clearing `model` reverts to the per-provider default;
  /// clearing `executorModel` reverts to `model`).
  static void write({
    AiProviderKind? provider,
    String? model,
    String? apiKey,
    String? plannerModel,
    String? executorModel,
    String? explainerModel,
    AgentMode? mode,
    String? language,
    String? baseUrl,
    int? maxSteps,
    String? path,
    String? home,
  }) {
    // Partition the requested changes: non-empty values are written, while
    // empty strings mean "clear" — the key is removed so resolution uses the
    // default. `null` values are skipped entirely (untouched).
    final fields = <String, Object?>{
      'provider': provider?.wireName,
      'model': model,
      'apiKey': apiKey,
      'plannerModel': plannerModel,
      'executorModel': executorModel,
      'explainerModel': explainerModel,
      'mode': mode?.wireName,
      'language': language,
      'baseUrl': baseUrl,
      'maxSteps': maxSteps,
    };
    final updates = <String, Object>{};
    final removals = <String>[];
    for (final e in fields.entries) {
      final v = e.value;
      if (v == null) continue;
      if (v is String && v.isEmpty) {
        removals.add(e.key);
      } else {
        updates[e.key] = v;
      }
    }
    if (updates.isEmpty && removals.isEmpty) return;

    final file = File(path ?? defaultPath(home: home));
    final existing = file.existsSync() ? file.readAsStringSync() : '';

    if (existing.trim().isEmpty) {
      // Nothing to remove from a fresh file; only the set values are written.
      if (updates.isEmpty) return;
      file.parent.createSync(recursive: true);
      _restrictDir(file.parent);
      file.writeAsStringSync(_template(updates));
      _restrictFile(file);
      return;
    }

    final doc = loadYaml(existing);
    if (doc is Map && doc['ai'] is Map) {
      final aiMap = doc['ai'] as Map;
      final editor = YamlEditor(existing);
      for (final e in updates.entries) {
        editor.update(['ai', e.key], e.value);
      }
      for (final key in removals) {
        if (aiMap.containsKey(key)) editor.remove(['ai', key]);
      }
      file.writeAsStringSync(editor.toString());
    } else if (doc is Map) {
      if (updates.isEmpty) return; // no `ai` map yet, nothing to remove
      final editor = YamlEditor(existing)..update(['ai'], updates);
      file.writeAsStringSync(editor.toString());
    } else {
      // Root is not a mapping (unexpected); replace with a fresh template.
      if (updates.isEmpty) return;
      file.writeAsStringSync(_template(updates));
    }
    _restrictFile(file);
  }

  /// Persists just the default [mode], preserving other entries.
  static void writeMode(AgentMode mode, {String? path, String? home}) =>
      write(mode: mode, path: path, home: home);

  static String _resolveModel(
    Map<String, String> env,
    Map<String, Object?> yaml,
    AiProviderKind provider,
  ) =>
      _str(env['OMNYSHELL_AI_MODEL']) ??
      _str(yaml['model']) ??
      defaultModelFor(provider);

  static String _template(Map<String, Object> updates) {
    final buf = StringBuffer()
      ..writeln('# ~/.omnyshell/ai.yaml — AI agent configuration')
      ..writeln('ai:');
    for (final e in updates.entries) {
      buf.writeln('  ${e.key}: ${_yamlScalar(e.value)}');
    }
    return buf.toString();
  }

  static String _yamlScalar(Object value) {
    if (value is num) return '$value';
    final s = '$value';
    return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  static Map<String, Object?> _readYaml(String path) {
    final file = File(path);
    if (!file.existsSync()) return const {};
    final text = file.readAsStringSync();
    if (text.trim().isEmpty) return const {};
    final doc = loadYaml(text);
    if (doc is Map && doc['ai'] is Map) {
      return (doc['ai'] as Map).map((k, v) => MapEntry('$k', v));
    }
    return const {};
  }

  static AiProviderKind? _inferProviderFromEnv(Map<String, String> env) {
    for (final entry in _envKeys.entries) {
      if (env[entry.value]?.trim().isNotEmpty == true) return entry.key;
    }
    return null;
  }

  /// Trims [value] to a non-empty string, or `null`.
  static String? _str(Object? value) {
    if (value is! String) return null;
    final t = value.trim();
    return t.isEmpty ? null : t;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static void _restrictFile(File file) {
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', file.path]);
      } catch (_) {}
    }
  }

  static void _restrictDir(Directory dir) {
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['700', dir.path]);
      } catch (_) {}
    }
  }
}
