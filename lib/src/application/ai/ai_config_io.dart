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
    required this.plannerModel,
    required this.executorModel,
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

  /// Per-phase model overrides; `null` means the phase uses [model].
  final String? plannerModel;
  final String? executorModel;
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

  /// Default models per provider, used only when `ai.yaml`/env do not specify
  /// them. Each provider gets a cheaper [model] (also the executor default) and
  /// a stronger [planner]; the executor has no separate default, so it falls
  /// back to [model]. All overridable in `ai.yaml` — kept here so a fresh
  /// install runs without hand-editing the file.
  static const _defaults = {
    AiProviderKind.anthropic: (
      model: 'claude-haiku-4-5',
      planner: 'claude-opus-4-8',
    ),
    AiProviderKind.openai: (model: 'gpt-4.1-mini', planner: 'gpt-5.4-mini'),
    AiProviderKind.gemini: (
      model: 'gemini-2.5-flash',
      planner: 'gemini-2.5-pro',
    ),
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
      plannerModel: _str(yaml['plannerModel']) ?? _defaults[provider]!.planner,
      executorModel: _str(yaml['executorModel']),
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
      plannerModel:
          _str(yaml['plannerModel']) ??
          (provider == null ? null : _defaults[provider]!.planner),
      executorModel: _str(yaml['executorModel']),
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
  static void write({
    AiProviderKind? provider,
    String? model,
    String? apiKey,
    String? plannerModel,
    String? executorModel,
    AgentMode? mode,
    String? language,
    String? baseUrl,
    int? maxSteps,
    String? path,
    String? home,
  }) {
    final updates = <String, Object>{
      'provider': ?provider?.wireName,
      'model': ?model,
      'apiKey': ?apiKey,
      'plannerModel': ?plannerModel,
      'executorModel': ?executorModel,
      'mode': ?mode?.wireName,
      'language': ?language,
      'baseUrl': ?baseUrl,
      'maxSteps': ?maxSteps,
    };
    if (updates.isEmpty) return;

    final file = File(path ?? defaultPath(home: home));
    final existing = file.existsSync() ? file.readAsStringSync() : '';

    if (existing.trim().isEmpty) {
      file.parent.createSync(recursive: true);
      _restrictDir(file.parent);
      file.writeAsStringSync(_template(updates));
      _restrictFile(file);
      return;
    }

    final doc = loadYaml(existing);
    if (doc is Map && doc['ai'] is Map) {
      final editor = YamlEditor(existing);
      for (final e in updates.entries) {
        editor.update(['ai', e.key], e.value);
      }
      file.writeAsStringSync(editor.toString());
    } else if (doc is Map) {
      final editor = YamlEditor(existing)..update(['ai'], updates);
      file.writeAsStringSync(editor.toString());
    } else {
      // Root is not a mapping (unexpected); replace with a fresh template.
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
      _defaults[provider]!.model;

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
