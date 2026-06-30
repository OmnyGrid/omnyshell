import 'dart:convert';

import '../../../../domain/backend/shell_family.dart';
import '../../client_runtime.dart';
import '../terminal/command_runner.dart';
import 'local_workspace.dart' show WorkspaceException;
import 'remote_command_runner.dart';
import 'workspace.dart';

/// A [Workspace] backed by a remote node over the connected [ClientRuntime].
///
/// File operations run as one-shot commands on the node (`ls`, `cat`, a
/// base64 round-trip for writes), so they need only a shell session — the same
/// channel the terminal and agent use — and work from the web client too. (A
/// drive-RPC byte transport can be layered in later for binary/large files.)
class RemoteWorkspace implements Workspace {
  RemoteWorkspace({
    required ClientRuntime client,
    required String nodeId,
    required this.rootPath,
    ShellFamily? shellFamily,
  }) : _client = client,
       _nodeId = nodeId,
       _shellFamily = shellFamily,
       commandRunner = RemoteCommandRunner(
         client: client,
         nodeId: nodeId,
         shellFamily: shellFamily,
       );

  final ClientRuntime _client;
  final String _nodeId;
  final ShellFamily? _shellFamily;

  @override
  final String rootPath;

  @override
  final CommandRunner commandRunner;

  @override
  bool get isRemote => true;

  /// Single-quotes [path] for safe POSIX shell interpolation.
  static String _q(String path) => "'${path.replaceAll("'", "'\\''")}'";

  Future<ExecResult> _run(String command) => _client.execute(
    nodeId: _nodeId,
    command: command,
    shellFamily: _shellFamily,
  );

  @override
  Future<List<WsEntry>> list(String absPath) async {
    // `-Ap` lists dotfiles (minus . / ..) and appends `/` to directory names.
    final r = await _run('ls -Ap -- ${_q(absPath)}');
    if (r.exitCode != 0) {
      throw WorkspaceException('cannot list $absPath: ${r.stderrText.trim()}');
    }
    final out = <WsEntry>[];
    for (final raw in const LineSplitter().convert(r.stdoutText)) {
      final name = raw.trimRight();
      if (name.isEmpty) continue;
      final isDir = name.endsWith('/');
      out.add(
        WsEntry(
          isDir ? name.substring(0, name.length - 1) : name,
          isDir: isDir,
        ),
      );
    }
    return out;
  }

  @override
  Future<String> read(String absPath) async {
    final r = await _run('cat -- ${_q(absPath)}');
    if (r.exitCode != 0) {
      throw WorkspaceException('cannot read $absPath: ${r.stderrText.trim()}');
    }
    return r.stdoutText;
  }

  @override
  Future<void> write(String absPath, String content) async {
    final b64 = base64.encode(utf8.encode(content));
    // Decode base64 on the node to avoid any shell-quoting of the content.
    final r = await _run('printf %s ${_q(b64)} | base64 -d > ${_q(absPath)}');
    if (r.exitCode != 0) {
      throw WorkspaceException('cannot write $absPath: ${r.stderrText.trim()}');
    }
  }

  @override
  Future<bool> exists(String absPath) async {
    final r = await _run('test -e ${_q(absPath)}');
    return r.exitCode == 0;
  }

  @override
  Future<bool> isDirectory(String absPath) async {
    final r = await _run('test -d ${_q(absPath)}');
    return r.exitCode == 0;
  }

  @override
  Future<void> createFile(String absPath) async {
    final r = await _run(
      'mkdir -p -- "\$(dirname -- ${_q(absPath)})" && touch -- ${_q(absPath)}',
    );
    if (r.exitCode != 0) {
      throw WorkspaceException(
        'cannot create $absPath: ${r.stderrText.trim()}',
      );
    }
  }

  @override
  Future<void> createDirectory(String absPath) async {
    final r = await _run('mkdir -p -- ${_q(absPath)}');
    if (r.exitCode != 0) {
      throw WorkspaceException(
        'cannot create $absPath: ${r.stderrText.trim()}',
      );
    }
  }

  @override
  Future<WsExecResult> exec(String command, {String? cwd}) async {
    final r = await _client.execute(
      nodeId: _nodeId,
      command: command,
      cwd: cwd ?? rootPath,
      shellFamily: _shellFamily,
    );
    return WsExecResult(
      exitCode: r.exitCode,
      stdout: r.stdoutText,
      stderr: r.stderrText,
    );
  }

  @override
  Future<void> close() async {}
}
