import 'package:command_shield/command_shield.dart';
import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// A provider stub — the help/usage paths never call it.
class _FakeProvider implements AiProvider {
  @override
  Future<AiResult> chat({
    required List<AiMessage> messages,
    required List<AiToolSpec> tools,
    String? model,
  }) async => const AiResult(stopReason: AiStopReason.endTurn);

  @override
  void close() {}
}

LocalCommandContext _ctx(List<String> out) => LocalCommandContext(
  client: ClientRuntime(
    ClientConfig(
      hubUri: Uri.parse('wss://localhost:1/'),
      credentials: const TokenCredentialProvider(
        principal: 'tester',
        token: 'tok',
      ),
    ),
  ),
  node: NodeDescriptor(
    id: NodeId('n1'),
    displayName: 'n1',
    platform: const PlatformInfo(
      os: 'linux',
      arch: 'x64',
      agentVersion: '1.0.0',
      hostname: 'host',
    ),
    online: true,
  ),
  startedAt: DateTime.now(),
  writeLine: out.add,
);

void main() {
  AiCommand command() => AiCommand(
    config: const AiConfig(
      provider: AiProviderKind.anthropic,
      model: 'm',
      apiKey: 'k',
    ),
    provider: _FakeProvider(),
    shield: CommandShield(),
  );

  group(':ai help', () {
    for (final arg in ['-h', '--help', 'help']) {
      test(':ai $arg prints usage without invoking the agent', () async {
        final out = <String>[];
        await command().run(_ctx(out), [arg]);
        final text = out.join('\n');
        expect(text, contains('Usage:'));
        expect(text, contains(':ai <prompt>'));
        expect(text, contains(':ai -h | --help'));
      });
    }

    test(':ai with no args also prints usage', () async {
      final out = <String>[];
      await command().run(_ctx(out), []);
      expect(out.join('\n'), contains('Usage:'));
    });
  });
}
