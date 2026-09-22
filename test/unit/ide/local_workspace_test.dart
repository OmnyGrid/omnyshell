@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyshell/src/application/client/ide/terminal/process_command_runner.dart';
import 'package:omnyshell/src/application/client/ide/workspace/local_workspace.dart';
import 'package:omnyshell/src/application/client/ide/workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late LocalWorkspace ws;

  setUp(() {
    root = Directory.systemTemp.createTempSync('omnyshell-ws-');
    ws = LocalWorkspace(root.path);
  });

  tearDown(() async {
    await ws.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// The workspace-absolute path of [name].
  String at(String name) => '${root.path}/$name';

  group('LocalWorkspace', () {
    test('normalises the root and reports itself as local', () {
      final quirky = LocalWorkspace('${root.path}/sub/..');

      expect(quirky.rootPath, root.path);
      expect(quirky.isRemote, isFalse);
      expect(quirky.commandRunner, isA<ProcessCommandRunner>());
    }, skip: Platform.isWindows ? 'POSIX path separators' : null);

    test('lists files and directories, flagging which is which', () async {
      File(at('a.txt')).writeAsStringSync('a');
      Directory(at('sub')).createSync();

      final entries = await ws.list(root.path);

      expect(entries.map((e) => e.name).toSet(), {'a.txt', 'sub'});
      expect(entries.firstWhere((e) => e.name == 'sub').isDir, isTrue);
      expect(entries.firstWhere((e) => e.name == 'a.txt').isDir, isFalse);
    });

    test('listing a directory that is not there fails by name', () async {
      await expectLater(
        ws.list(at('absent')),
        throwsA(
          isA<WorkspaceException>().having(
            (e) => e.message,
            'message',
            contains('no such directory'),
          ),
        ),
      );
    });

    test('reads a file back', () async {
      File(at('a.txt')).writeAsStringSync('hello');

      expect(await ws.read(at('a.txt')), 'hello');
    });

    test('reading a file that is not there fails by name', () async {
      await expectLater(
        ws.read(at('absent.txt')),
        throwsA(
          isA<WorkspaceException>().having(
            (e) => '$e',
            'toString',
            contains('no such file'),
          ),
        ),
      );
    });

    test('writes a file, creating the parent directories', () async {
      await ws.write(at('deep/nested/a.txt'), 'content');

      expect(File(at('deep/nested/a.txt')).readAsStringSync(), 'content');
    });

    test('writing over an existing file replaces it', () async {
      await ws.write(at('a.txt'), 'first');
      await ws.write(at('a.txt'), 'second');

      expect(await ws.read(at('a.txt')), 'second');
    });

    test('exists covers files, directories and neither', () async {
      File(at('a.txt')).writeAsStringSync('a');
      Directory(at('sub')).createSync();

      expect(await ws.exists(at('a.txt')), isTrue);
      expect(await ws.exists(at('sub')), isTrue);
      expect(await ws.exists(at('absent')), isFalse);
    });

    test('isDirectory is true only for directories', () async {
      File(at('a.txt')).writeAsStringSync('a');
      Directory(at('sub')).createSync();

      expect(await ws.isDirectory(at('sub')), isTrue);
      expect(await ws.isDirectory(at('a.txt')), isFalse);
      expect(await ws.isDirectory(at('absent')), isFalse);
    });

    test('createFile makes an empty file and its parents', () async {
      await ws.createFile(at('deep/new.txt'));

      expect(File(at('deep/new.txt')).existsSync(), isTrue);
      expect(await ws.read(at('deep/new.txt')), isEmpty);
    });

    test('createDirectory is recursive', () async {
      await ws.createDirectory(at('a/b/c'));

      expect(Directory(at('a/b/c')).existsSync(), isTrue);
    });

    test('exec captures stdout and a zero exit code', () async {
      final result = await ws.exec('echo hello-workspace');

      expect(result.exitCode, 0);
      expect(result.ok, isTrue);
      expect(result.stdout.trim(), 'hello-workspace');
      expect(result.stderr, isEmpty);
    });

    test('exec captures stderr and a failing exit code', () async {
      final result = await ws.exec('echo oops >&2; exit 3');

      expect(result.exitCode, 3);
      expect(result.ok, isFalse);
      expect(result.stderr.trim(), 'oops');
    });

    test('exec runs in the root by default, or in an explicit cwd', () async {
      Directory(at('sub')).createSync();

      final inRoot = await ws.exec('pwd');
      final inSub = await ws.exec('pwd', cwd: at('sub'));

      expect(
        Directory(inRoot.stdout.trim()).resolveSymbolicLinksSync(),
        root.resolveSymbolicLinksSync(),
      );
      expect(
        Directory(inSub.stdout.trim()).resolveSymbolicLinksSync(),
        Directory(at('sub')).resolveSymbolicLinksSync(),
      );
    });

    test('close is safe to call more than once', () async {
      await ws.close();
      await ws.close();
    });
  }, skip: Platform.isWindows ? 'POSIX shell semantics' : null);

  group('ProcessCommandRunner', () {
    const runner = ProcessCommandRunner();

    test('streams output lines and completes with the exit code', () async {
      final execution = runner.run('echo one; echo two', root.path);

      final lines = await execution.output.toList();

      expect(lines, ['one', 'two']);
      expect(await execution.exitCode, 0);
    });

    test('merges stderr into the same stream', () async {
      final execution = runner.run('echo out; echo err >&2', root.path);

      final lines = await execution.output.toList();

      expect(lines, containsAll(['out', 'err']));
    });

    test('reports a non-zero exit code', () async {
      final execution = runner.run('exit 7', root.path);

      expect(await execution.output.toList(), isEmpty);
      expect(await execution.exitCode, 7);
    });

    test('runs in the directory it is given', () async {
      Directory(at('sub')).createSync();

      final execution = runner.run('pwd', at('sub'));
      final out = (await execution.output.toList()).single;

      expect(
        Directory(out).resolveSymbolicLinksSync(),
        Directory(at('sub')).resolveSymbolicLinksSync(),
      );
    });

    test('kill terminates a command that would otherwise hang', () async {
      // `exec` replaces the shell with sleep, so killing the process Dart
      // spawned really does close the pipes — a plain `sleep 30` would leave
      // an orphan holding stdout open for the full 30 seconds.
      final execution = runner.run('exec sleep 30', root.path);
      // Give the process time to actually start before signalling it.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      execution.kill();

      expect(await execution.exitCode, isNot(0));
    });

    test('kill before the process has started is a no-op', () async {
      final execution = runner.run('true', root.path);

      expect(execution.kill, returnsNormally);
      expect(await execution.exitCode, 0);
    });

    // The runner used to await the stream close before completing the exit
    // code. A single-subscription stream nobody listens to never delivers its
    // done event, so the exit code of a run whose output was ignored never
    // arrived — and the caller waited forever.
    test('reports the exit code even when nobody reads the output', () async {
      final execution = runner.run('echo ignored; exit 5', root.path);

      expect(await execution.exitCode, 5);
    });

    test('a later listener still receives the buffered output', () async {
      final execution = runner.run('echo one; echo two', root.path);

      expect(await execution.exitCode, 0);
      // Subscribing only after the run finished: the lines were buffered and
      // the done event is still waiting to be delivered.
      expect(await execution.output.toList(), ['one', 'two']);
    });

    test('a shell that cannot run surfaces the error', () async {
      final execution = runner.run('true', '${root.path}/absent-cwd');

      // The spawn fails, so both the stream and the exit code report it —
      // listened to together, since either one left alone would be an
      // unhandled async error.
      await Future.wait([
        expectLater(execution.output, emitsError(isA<Object>())),
        expectLater(execution.exitCode, throwsA(isA<Object>())),
      ]);
    });
  }, skip: Platform.isWindows ? 'POSIX shell semantics' : null);
}
