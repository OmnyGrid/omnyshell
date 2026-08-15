@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

void main() {
  group('localCompletionCandidates', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('omnyshell-local-completion');
      File('${dir.path}/alpha.txt').writeAsStringSync('a');
      File('${dir.path}/alphabet.txt').writeAsStringSync('b');
      Directory('${dir.path}/alpine').createSync();
      File('${dir.path}/beta.txt').writeAsStringSync('c');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('completes file prefixes in cwd, marking directories', () async {
      final candidates = await localCompletionCandidates(
        ProcessShellBackend(),
        ShellDialect.forFamily(ShellFamily.posix),
        'alp',
        isCommand: false,
        family: ShellFamily.posix,
        cwd: dir.path,
      );

      expect(candidates, containsAll(['alpha.txt', 'alphabet.txt']));
      expect(candidates, contains('alpine/')); // directories get a trailing /
      expect(candidates, isNot(contains('beta.txt')));
    }, onPlatform: const {'windows': Skip('POSIX completion command')});

    test('command-position completion finds an executable on PATH', () async {
      final candidates = await localCompletionCandidates(
        ProcessShellBackend(),
        ShellDialect.forFamily(ShellFamily.posix),
        'ec',
        isCommand: true,
        family: ShellFamily.posix,
      );

      expect(candidates, contains('echo'));
    }, onPlatform: const {'windows': Skip('POSIX completion command')});
  });
}
