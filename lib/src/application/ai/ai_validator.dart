import 'providers/ai_provider.dart';

/// The outcome of validating one model with a live provider request.
class AiModelCheck {
  const AiModelCheck({
    required this.model,
    required this.ok,
    this.error,
    this.latencyMs,
  });

  final String model;

  /// Whether the request succeeded (the key and model are usable).
  final bool ok;

  /// The failure message when [ok] is false (e.g. `401: invalid x-api-key`).
  final String? error;

  /// Round-trip time of the validation request, in milliseconds.
  final int? latencyMs;
}

/// Validates [models] against [provider] by sending a minimal, tool-free
/// request per model — confirming the API key works and each model id is
/// accepted. Errors are captured per model rather than thrown, so one bad model
/// does not hide the others.
///
/// Pure Dart (no `dart:io`): the caller injects the provider, so this is
/// unit-testable with a fake.
Future<List<AiModelCheck>> validateModels(
  AiProvider provider,
  List<String> models,
) async {
  final results = <AiModelCheck>[];
  for (final model in models) {
    final sw = Stopwatch()..start();
    try {
      await provider.chat(
        messages: const [AiMessage.user('ping')],
        tools: const [],
        model: model,
      );
      sw.stop();
      results.add(
        AiModelCheck(model: model, ok: true, latencyMs: sw.elapsedMilliseconds),
      );
    } on AiProviderException catch (e) {
      sw.stop();
      results.add(AiModelCheck(model: model, ok: false, error: e.message));
    } catch (e) {
      sw.stop();
      results.add(AiModelCheck(model: model, ok: false, error: '$e'));
    }
  }
  return results;
}
