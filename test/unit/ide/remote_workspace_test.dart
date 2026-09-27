@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnyshell/src/application/client/client_runtime.dart';
import 'package:omnyshell/src/application/client/ide/workspace/remote_command_runner.dart';
import 'package:omnyshell/src/application/client/ide/workspace/remote_workspace.dart';
import 'package:omnyshell/src/application/client/ide/workspace/workspace.dart';
import 'package:omnyshell/src/domain/backend/shell_family.dart';
import 'package:test/test.dart';

/// One `execute`/`executeStreaming` call as the fake saw it.
typedef _Call = ({
  String nodeId,
  String command,
  String? cwd,
  ShellFamily? shellFamily,
});

/// A [ClientRuntime] stand-in for the two calls the remote workspace and
/// runner make. [onExecute] answers `execute`; [onStream] drives
/// `executeStreaming` (feeding the stdout/stderr callbacks). Anything else is
/// unexpected and throws.
class _FakeClient implements ClientRuntime {
  _FakeClient({this.onExecute, this.onStream});

  final Future<ExecResult> Function(_Call call)? onExecute;
  final Future<int> Function(
    _Call call,
    void Function(List<int>) onStdout,
    void Function(List<int>) onStderr,
  )?
  onStream;

  final List<_Call> calls = [];

  @override
  Future<ExecResult> execute({
    required String nodeId,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    String? cwd,
    ShellFamily? shellFamily,
  }) {
    final call = (
      nodeId: nodeId,
      command: command,
      cwd: cwd,
      shellFamily: shellFamily,
    );
    calls.add(call);
    return onExecute!(call);
  }

  @override
  Future<int> executeStreaming({
    required String nodeId,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    String? cwd,
    ShellFamily? shellFamily,
    required void Function(List<int> chunk) onStdout,
    required void Function(List<int> chunk) onStderr,
  }) {
    final call = (
      nodeId: nodeId,
      command: command,
      cwd: cwd,
      shellFamily: shellFamily,
    );
    calls.add(call);
    return onStream!(call, onStdout, onStderr);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

ExecResult _result(int code, {String out = '', String err = ''}) => ExecResult(
  exitCode: code,
  stdout: Uint8List.fromList(utf8.encode(out)),
  stderr: Uint8List.fromList(utf8.encode(err)),
);

/// A client whose `execute` runs the command in a real local `sh`, standing in
/// for the node — so the workspace's actual shell commands are exercised.
_FakeClient _shellClient() => _FakeClient(
  onExecute: (call) async {
    final r = await Process.run(
      'sh',
      ['-c', call.command],
      workingDirectory: call.cwd,
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    return ExecResult(
      exitCode: r.exitCode,
      stdout: Uint8List.fromList(r.stdout as List<int>),
      stderr: Uint8List.fromList(r.stderr as List<int>),
    );
  },
);

void main() {
  group('RemoteWorkspace over a real shell', () {
    late Directory tmp;
    late RemoteWorkspace ws;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('remote_ws_test');
      ws = RemoteWorkspace(
        client: _shellClient(),
        nodeId: 'node-1',
        rootPath: tmp.path,
      );
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('is remote and runs commands through a RemoteCommandRunner', () {
      expect(ws.isRemote, isTrue);
      expect(ws.rootPath, tmp.path);
      expect(ws.commandRunner, isA<RemoteCommandRunner>());
    });

    test('list reports files, directories and dot-files', () async {
      Directory('${tmp.path}/src').createSync();
      File('${tmp.path}/a.txt').writeAsStringSync('');
      File('${tmp.path}/.env').writeAsStringSync('');

      final entries = await ws.list(tmp.path);
      final byName = {for (final e in entries) e.name: e.isDir};

      expect(byName, {'src': true, 'a.txt': false, '.env': false});
    });

    test('list of a missing directory throws a WorkspaceException', () {
      expect(
        ws.list('${tmp.path}/nope'),
        throwsA(
          isA<WorkspaceException>().having(
            (e) => e.toString(),
            'message',
            contains('cannot list'),
          ),
        ),
      );
    });

    test('write then read round-trips content, including quotes', () async {
      final path = "${tmp.path}/it's here.txt";
      const content = 'line 1\n\$HOME "quoted" \'single\' `tick`\nünïcode ✓\n';

      await ws.write(path, content);

      expect(File(path).readAsStringSync(), content);
      expect(await ws.read(path), content);
    });

    test('read of a missing file throws a WorkspaceException', () {
      expect(
        ws.read('${tmp.path}/missing.txt'),
        throwsA(isA<WorkspaceException>()),
      );
    });

    test('write into a missing directory throws a WorkspaceException', () {
      expect(
        ws.write('${tmp.path}/no/such/dir/f.txt', 'x'),
        throwsA(isA<WorkspaceException>()),
      );
    });

    test('exists and isDirectory', () async {
      File('${tmp.path}/f').writeAsStringSync('');

      expect(await ws.exists('${tmp.path}/f'), isTrue);
      expect(await ws.isDirectory('${tmp.path}/f'), isFalse);
      expect(await ws.isDirectory(tmp.path), isTrue);
      expect(await ws.exists('${tmp.path}/nope'), isFalse);
    });

    test('createFile creates missing parent directories', () async {
      final path = '${tmp.path}/deep/er/new.dart';

      await ws.createFile(path);

      expect(File(path).existsSync(), isTrue);
      expect(File(path).lengthSync(), 0);
    });

    test('createDirectory creates nested directories', () async {
      await ws.createDirectory('${tmp.path}/x/y/z');

      expect(Directory('${tmp.path}/x/y/z').existsSync(), isTrue);
    });

    test('create under a regular file throws a WorkspaceException', () async {
      File('${tmp.path}/file').writeAsStringSync('');

      await expectLater(
        ws.createFile('${tmp.path}/file/child'),
        throwsA(isA<WorkspaceException>()),
      );
      await expectLater(
        ws.createDirectory('${tmp.path}/file/child'),
        throwsA(isA<WorkspaceException>()),
      );
    });

    test('exec runs in the root by default, or in the given cwd', () async {
      Directory('${tmp.path}/sub').createSync();

      final inRoot = await ws.exec('ls');
      expect(inRoot.exitCode, 0);
      expect(inRoot.stdout, contains('sub'));

      File('${tmp.path}/sub/only-here').writeAsStringSync('');
      final inSub = await ws.exec('ls', cwd: '${tmp.path}/sub');
      expect(inSub.stdout.trim(), 'only-here');
    });

    test('exec reports a failing command', () async {
      final r = await ws.exec('echo oops >&2; exit 3');

      expect(r.exitCode, 3);
      expect(r.stderr.trim(), 'oops');
    });
  }, testOn: '!windows');

  group('RemoteWorkspace command shape', () {
    test('targets the node with its shell family and quotes paths', () async {
      final client = _FakeClient(onExecute: (_) async => _result(0));
      final ws = RemoteWorkspace(
        client: client,
        nodeId: 'n7',
        rootPath: '/r',
        shellFamily: ShellFamily.posix,
      );

      await ws.exists("/r/it's");

      final call = client.calls.single;
      expect(call.nodeId, 'n7');
      expect(call.shellFamily, ShellFamily.posix);
      expect(call.command, "test -e '/r/it'\\''s'");
      await ws.close(); // a no-op, but must not throw
    });

    test('error messages carry the trimmed stderr', () {
      final client = _FakeClient(
        onExecute: (_) async => _result(1, err: '  permission denied\n'),
      );
      final ws = RemoteWorkspace(client: client, nodeId: 'n', rootPath: '/');

      expect(
        ws.read('/secret'),
        throwsA(
          isA<WorkspaceException>().having(
            (e) => e.toString(),
            'message',
            contains('cannot read /secret: permission denied'),
          ),
        ),
      );
    });
  });

  group('RemoteCommandRunner', () {
    test('splits streamed chunks into lines and completes the exit code', () {
      final client = _FakeClient(
        onStream: (call, onStdout, onStderr) async {
          // Lines split across chunks, CRLF endings and a trailing partial.
          onStdout(utf8.encode('hel'));
          onStdout(utf8.encode('lo\r\nwor'));
          onStderr(utf8.encode('warn\n'));
          onStdout(utf8.encode('ld\ntail'));
          return 4;
        },
      );
      final runner = RemoteCommandRunner(
        client: client,
        nodeId: 'n1',
        shellFamily: ShellFamily.posix,
      );

      final exec = runner.run('make', '/work');

      expect(
        exec.output,
        emitsInOrder(['hello', 'warn', 'world', 'tail', emitsDone]),
      );
      expect(exec.exitCode, completion(4));
      exec.kill(); // best-effort no-op
      final call = client.calls.single;
      expect(call.command, 'make');
      expect(call.cwd, '/work');
      expect(call.nodeId, 'n1');
      expect(call.shellFamily, ShellFamily.posix);
    });

    test('decodes multi-byte characters split across chunks', () {
      final bytes = utf8.encode('ü\n');
      final client = _FakeClient(
        onStream: (call, onStdout, onStderr) async {
          onStdout(bytes.sublist(0, 1));
          onStdout(bytes.sublist(1));
          return 0;
        },
      );

      final exec = RemoteCommandRunner(
        client: client,
        nodeId: 'n',
      ).run('x', '/');

      expect(exec.output, emitsInOrder(['ü', emitsDone]));
    });

    test('a failed remote exec surfaces as an error on both futures', () {
      final client = _FakeClient(
        onStream: (call, onStdout, onStderr) async =>
            throw StateError('node offline'),
      );

      final exec = RemoteCommandRunner(
        client: client,
        nodeId: 'n',
      ).run('x', '/');

      expect(exec.output, emitsInOrder([emitsError(isStateError), emitsDone]));
      expect(exec.exitCode, throwsStateError);
    });
  });
}
