import '../terminal/command_runner.dart';

/// A directory entry returned by [Workspace.list].
class WsEntry {
  const WsEntry(this.name, {required this.isDir});
  final String name;
  final bool isDir;
}

/// The result of a one-shot command run via [Workspace.exec].
class WsExecResult {
  const WsExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
}

/// The filesystem + command operations the IDE runs against.
///
/// Abstracting these behind an async, `dart:io`-free port lets the same IDE
/// engine target the local filesystem ([rootPath] on this machine), a remote
/// node over the connected client, or a host web app — and keeps the engine
/// compilable to JavaScript. All paths are absolute and rooted under
/// [rootPath]; implementations resolve and (for remote) sandbox them.
abstract class Workspace {
  /// The absolute root the IDE is opened on.
  String get rootPath;

  /// Whether this targets a remote node (drives UI labels like the title bar).
  bool get isRemote;

  /// Lists the entries of directory [absPath].
  Future<List<WsEntry>> list(String absPath);

  /// Reads the UTF-8 contents of file [absPath].
  Future<String> read(String absPath);

  /// Creates or overwrites file [absPath] with [content].
  Future<void> write(String absPath, String content);

  /// Whether [absPath] exists (file or directory).
  Future<bool> exists(String absPath);

  /// Whether [absPath] exists and is a directory.
  Future<bool> isDirectory(String absPath);

  /// Creates an empty file at [absPath] (with parent directories).
  Future<void> createFile(String absPath);

  /// Creates a directory at [absPath] (recursively).
  Future<void> createDirectory(String absPath);

  /// The streaming command runner backing the terminal panel and the agent's
  /// `run_command` tool — local process or remote exec.
  CommandRunner get commandRunner;

  /// Runs [command] once and returns its captured output (used for git). [cwd]
  /// defaults to [rootPath].
  Future<WsExecResult> exec(String command, {String? cwd});

  /// Releases any resources (sessions, clients). Safe to call once.
  Future<void> close();
}

/// Thrown by [Workspace] operations on bad paths or I/O failures.
///
/// Lives here, in the `dart:io`-free port, so both [Workspace] implementations
/// (local and remote) and web embedders can share it without dragging in
/// `dart:io`.
class WorkspaceException implements Exception {
  WorkspaceException(this.message);
  final String message;
  @override
  String toString() => message;
}
