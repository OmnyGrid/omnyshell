import 'dart:io';

import 'package:path/path.dart' as p;

import '../terminal/command_runner.dart';
import '../terminal/process_command_runner.dart';
import 'workspace.dart';

/// A [Workspace] backed by the local filesystem (`dart:io`). Used by
/// `omnyshell local` and any native local-directory `:ide` session.
class LocalWorkspace implements Workspace {
  LocalWorkspace(String rootPath)
    : rootPath = p.normalize(p.absolute(rootPath)),
      commandRunner = const ProcessCommandRunner();

  @override
  final String rootPath;

  @override
  final CommandRunner commandRunner;

  @override
  bool get isRemote => false;

  @override
  Future<List<WsEntry>> list(String absPath) async {
    final dir = Directory(absPath);
    if (!dir.existsSync()) {
      throw WorkspaceException('no such directory: $absPath');
    }
    return [
      for (final e in dir.listSync())
        WsEntry(p.basename(e.path), isDir: e is Directory),
    ];
  }

  @override
  Future<String> read(String absPath) async {
    final file = File(absPath);
    if (!file.existsSync()) {
      throw WorkspaceException('no such file: $absPath');
    }
    return file.readAsStringSync();
  }

  @override
  Future<void> write(String absPath, String content) async {
    File(absPath).parent.createSync(recursive: true);
    File(absPath).writeAsStringSync(content);
  }

  @override
  Future<bool> exists(String absPath) async =>
      File(absPath).existsSync() || Directory(absPath).existsSync();

  @override
  Future<bool> isDirectory(String absPath) async =>
      Directory(absPath).existsSync();

  @override
  Future<void> createFile(String absPath) async {
    final file = File(absPath);
    file.parent.createSync(recursive: true);
    file.createSync();
  }

  @override
  Future<void> createDirectory(String absPath) async =>
      Directory(absPath).createSync(recursive: true);

  @override
  Future<WsExecResult> exec(String command, {String? cwd}) async {
    final shell = Platform.isWindows
        ? (Platform.environment['ComSpec'] ?? 'cmd.exe')
        : (Platform.environment['SHELL'] ?? '/bin/sh');
    final args = Platform.isWindows ? ['/c', command] : ['-c', command];
    final r = await Process.run(shell, args, workingDirectory: cwd ?? rootPath);
    return WsExecResult(
      exitCode: r.exitCode,
      stdout: '${r.stdout}',
      stderr: '${r.stderr}',
    );
  }

  @override
  Future<void> close() async {}
}
