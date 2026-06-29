import 'package:omnyshell/src/application/ai/ai_validator.dart';
import 'package:omnyshell/src/application/ai/providers/ai_provider.dart';
import 'package:test/test.dart';

/// A provider that records the models it was asked to validate and fails for a
/// configured model id.
class FakeProvider implements AiProvider {
  FakeProvider({this.failModel, this.failMessage = 'boom'});

  final String? failModel;
  final String failMessage;
  final List<String?> asked = [];

  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) async {
    asked.add(model);
    if (model == failModel) {
      throw AiProviderException(failMessage, statusCode: 401);
    }
    return const AiResult(text: 'pong', stopReason: AiStopReason.endTurn);
  }

  @override
  void close() {}
}

void main() {
  group('validateModels', () {
    test('reports ok for each model and pings each one tool-free', () async {
      final provider = FakeProvider();
      final results = await validateModels(provider, ['m1', 'm2']);

      expect(provider.asked, ['m1', 'm2']);
      expect(results.map((r) => r.model), ['m1', 'm2']);
      expect(results.every((r) => r.ok), isTrue);
      expect(results.every((r) => r.latencyMs != null), isTrue);
    });

    test(
      'captures a per-model failure without throwing or hiding others',
      () async {
        final provider = FakeProvider(
          failModel: 'bad',
          failMessage: 'invalid key',
        );
        final results = await validateModels(provider, ['good', 'bad']);

        expect(results[0].ok, isTrue);
        expect(results[1].ok, isFalse);
        expect(results[1].error, 'invalid key');
      },
    );
  });
}
