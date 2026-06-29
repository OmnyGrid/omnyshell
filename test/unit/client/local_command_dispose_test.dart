import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// Records whether it was disposed.
class _DisposableCommand extends LocalCommand {
  _DisposableCommand(this.name);

  @override
  final String name;
  int disposed = 0;

  @override
  String get description => 'test';

  @override
  Future<void> run(LocalCommandContext context, List<String> args) async {}

  @override
  Future<void> dispose() async => disposed++;
}

void main() {
  test('registry.dispose disposes each registered command once', () async {
    final a = _DisposableCommand('a');
    final b = _DisposableCommand('b');
    final registry = LocalCommandRegistry()
      ..register(a)
      ..register(b);

    await registry.dispose();

    expect(a.disposed, 1);
    expect(b.disposed, 1);
  });

  test('registry.dispose ignores a command that throws on dispose', () async {
    final ok = _DisposableCommand('ok');
    final registry = LocalCommandRegistry()
      ..register(_ThrowingCommand())
      ..register(ok);

    await registry.dispose(); // must not throw

    expect(ok.disposed, 1);
  });
}

class _ThrowingCommand extends LocalCommand {
  @override
  String get name => 'boom';

  @override
  String get description => 'throws on dispose';

  @override
  Future<void> run(LocalCommandContext context, List<String> args) async {}

  @override
  Future<void> dispose() async => throw StateError('nope');
}
