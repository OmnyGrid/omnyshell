import 'dart:convert';

import '../../../../domain/backend/shell_family.dart';
import '../../client_runtime.dart';
import '../ide_command_support.dart'
    show isWindowsRemotePath, normalizeRemotePath;
import '../terminal/command_runner.dart';
import 'remote_command_runner.dart';
import 'workspace.dart';

/// A [Workspace] backed by a remote node over the connected [ClientRuntime].
///
/// File operations run as one-shot commands on the node, so they need only a
/// shell session — the same channel the terminal and agent use — and work from
/// the web client too. (A drive-RPC byte transport can be layered in later for
/// binary/large files.)
///
/// - On a POSIX node (or a Windows node whose shell is Git Bash, whose paths
///   are POSIX — `/c/…`): `ls`, `cat`, `touch`, `mkdir`, `test`.
/// - On a Windows node ([rootPath] is a Windows path: its shell is PowerShell
///   or `cmd`): PowerShell — present on every Windows — with .NET's file APIs,
///   which take paths literally (no wildcards). Listings and file contents
///   travel as base64 of their UTF-8 bytes, and error messages as UTF-8
///   bytes, so names and text survive PowerShell's console code page. Paths
///   are in Windows' native form (see [normalizeRemotePath]).
///
/// A write streams the content over the command's stdin, whatever its size,
/// into a temporary file first: only once all of it has arrived is the target
/// overwritten, so a dropped connection never leaves it truncated.
class RemoteWorkspace implements Workspace {
  RemoteWorkspace({
    required ClientRuntime client,
    required String nodeId,
    required String rootPath,
    ShellFamily? shellFamily,
  }) : _client = client,
       _nodeId = nodeId,
       _shellFamily = shellFamily,
       _windows = isWindowsRemotePath(rootPath),
       rootPath = normalizeRemotePath(rootPath),
       commandRunner = RemoteCommandRunner(
         client: client,
         nodeId: nodeId,
         shellFamily: shellFamily,
       );

  final ClientRuntime _client;
  final String _nodeId;
  final ShellFamily? _shellFamily;

  /// Whether file operations go through PowerShell: the node's paths are
  /// Windows paths (Git Bash, with its `/c/…` paths, takes the POSIX ones).
  final bool _windows;

  @override
  final String rootPath;

  @override
  final CommandRunner commandRunner;

  @override
  bool get isRemote => true;

  /// Single-quotes [path] for safe POSIX shell interpolation.
  static String _q(String path) => "'${path.replaceAll("'", "'\\''")}'";

  /// Runs this node's file-operation [command] — POSIX, or [windows] for a
  /// Windows node, which runs under PowerShell whatever the session's shell.
  Future<ExecResult> _run(
    String command, {
    String? windows,
    List<int>? stdin,
  }) => _client.execute(
    nodeId: _nodeId,
    command: _windows ? windows! : command,
    shellFamily: _windows ? ShellFamily.powershell : _shellFamily,
    stdin: stdin,
  );

  /// [r] when it succeeded; otherwise throws [_failure].
  static ExecResult _check(ExecResult r, String action, String absPath) =>
      r.exitCode == 0 ? r : throw _failure(r, action, absPath);

  /// The [WorkspaceException] for a command [r] that could not [action]
  /// [absPath], with the node's message.
  static WorkspaceException _failure(
    ExecResult r,
    String action,
    String absPath,
  ) {
    final detail = r.stderrText.trim();
    return WorkspaceException(
      'cannot $action $absPath'
      '${detail.isEmpty ? ' (exit ${r.exitCode})' : ': $detail'}',
    );
  }

  /// The answer of a yes/no probe: exit 0 is yes, 1 is no; anything else (the
  /// shell failed to start, a bad path) is an error, not a "no" — a caller
  /// about to create [absPath] must not take it as absent.
  static bool _probe(ExecResult r, String absPath) => switch (r.exitCode) {
    0 => true,
    1 => false,
    _ => throw _failure(r, 'check', absPath),
  };

  @override
  Future<List<WsEntry>> list(String absPath) async {
    // `-Ap` lists dotfiles (minus . / ..) and appends `/` to directory names.
    final r = _check(
      await _run(
        'ls -Ap -- ${_q(absPath)}',
        windows: windowsListScript(absPath),
      ),
      'list',
      absPath,
    );
    final listing = _windows ? _fromBase64(r.stdoutText) : r.stdoutText;
    final out = <WsEntry>[];
    for (final raw in const LineSplitter().convert(listing)) {
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
    final r = _check(
      await _run('cat -- ${_q(absPath)}', windows: windowsReadScript(absPath)),
      'read',
      absPath,
    );
    return _windows ? _fromBase64(r.stdoutText) : r.stdoutText;
  }

  @override
  Future<void> write(String absPath, String content) async {
    _check(
      await _run(
        posixWriteCommand(absPath),
        windows: windowsWriteScript(absPath),
        stdin: utf8.encode(content),
      ),
      'write',
      absPath,
    );
  }

  @override
  Future<bool> exists(String absPath) async => _probe(
    await _run(
      'test -e ${_q(absPath)}',
      windows: windowsTestPathScript(absPath),
    ),
    absPath,
  );

  @override
  Future<bool> isDirectory(String absPath) async => _probe(
    await _run(
      'test -d ${_q(absPath)}',
      windows: windowsTestPathScript(absPath, directory: true),
    ),
    absPath,
  );

  @override
  Future<void> createFile(String absPath) async {
    _check(
      await _run(
        'mkdir -p -- "\$(dirname -- ${_q(absPath)})" && '
        'touch -- ${_q(absPath)}',
        windows: windowsCreateFileScript(absPath),
      ),
      'create',
      absPath,
    );
  }

  @override
  Future<void> createDirectory(String absPath) async {
    _check(
      await _run(
        'mkdir -p -- ${_q(absPath)}',
        windows: windowsCreateDirectoryScript(absPath),
      ),
      'create',
      absPath,
    );
  }

  /// The UTF-8 text a Windows script sent as base64 (output is ASCII, so
  /// PowerShell's console code page cannot mangle it).
  static String _fromBase64(String stdout) {
    final b64 = stdout.trim();
    return b64.isEmpty
        ? ''
        : utf8.decode(base64.decode(b64), allowMalformed: true);
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

/// The POSIX command that writes its stdin to file [path]: into a temporary
/// file first, and onto [path] only once all of it has arrived — copied into
/// the existing file (not moved over it), so its mode and owner stay.
String posixWriteCommand(String path) {
  final q = "'${path.replaceAll("'", "'\\''")}'";
  return 't=\$(mktemp) || exit 1; cat > "\$t" && cat < "\$t" > $q; '
      's=\$?; rm -f "\$t"; exit \$s';
}

/// [s] as a PowerShell single-quoted string literal.
String _psq(String s) => "'${s.replaceAll("'", "''")}'";

/// [body] run so that a failure exits 1 with its message on stderr, and
/// success exits 0 — PowerShell's own exit code says neither reliably. The
/// message goes out as UTF-8 bytes, past the console code page, so a path
/// like `ação.txt` in it reads back intact.
///
/// The scripts use no double quotes: they reach `powershell.exe` as one
/// `-Command` argument through Windows' command-line quoting, which is where
/// embedded double quotes go wrong.
String _psTry(String body) =>
    "try { \$ErrorActionPreference = 'Stop'; $body; exit 0 } "
    'catch { \$m = [Text.Encoding]::UTF8.GetBytes(\$_.Exception.Message); '
    '\$e = [Console]::OpenStandardError(); \$e.Write(\$m, 0, \$m.Length); '
    '\$e.Flush(); exit 1 }';

/// Lists [path] — dot-entries included, directories suffixed with `/`, one
/// per line — and prints the listing as base64 of its UTF-8 bytes.
String windowsListScript(String path) => _psTry(
  '\$n = @(Get-ChildItem -Force -LiteralPath ${_psq(path)} | '
  "ForEach-Object { if (\$_.PSIsContainer) { \$_.Name + '/' } "
  'else { \$_.Name } }); '
  '[Console]::Out.Write([Convert]::ToBase64String('
  '[Text.Encoding]::UTF8.GetBytes(\$n -join [char]10)))',
);

/// Prints the bytes of file [path] as base64.
String windowsReadScript(String path) => _psTry(
  '[Console]::Out.Write([Convert]::ToBase64String('
  '[IO.File]::ReadAllBytes(${_psq(path)})))',
);

/// Writes the script's stdin, as raw bytes, to file [path]: into a temporary
/// file first, and onto [path] only once all of it has arrived (the copy
/// keeps [path] itself, not a moved-in replacement); the temporary file is
/// removed either way.
String windowsWriteScript(String path) => _psTry(
  '\$t = [IO.Path]::GetTempFileName(); '
  'try { \$i = [Console]::OpenStandardInput(); '
  '\$f = [IO.File]::Create(\$t); '
  'try { \$i.CopyTo(\$f) } finally { \$f.Dispose() }; '
  '[IO.File]::Copy(\$t, ${_psq(path)}, \$true) } '
  'finally { [IO.File]::Delete(\$t) }',
);

/// Exits 0 when [path] exists — as a directory, if [directory] — and 1 when
/// not (an error, being neither, exits otherwise).
String windowsTestPathScript(String path, {bool directory = false}) =>
    'if (Test-Path -LiteralPath ${_psq(path)}'
    '${directory ? ' -PathType Container' : ''}) { exit 0 } else { exit 1 }';

/// Creates file [path] (and its parent directories) if missing, or updates
/// its modification time — what `mkdir -p … && touch …` does.
String windowsCreateFileScript(String path) => _psTry(
  '\$d = [IO.Path]::GetDirectoryName(${_psq(path)}); '
  'if (\$d) { [void][IO.Directory]::CreateDirectory(\$d) }; '
  'if ([IO.File]::Exists(${_psq(path)})) '
  '{ [IO.File]::SetLastWriteTime(${_psq(path)}, [DateTime]::Now) } '
  'else { [IO.File]::WriteAllBytes(${_psq(path)}, [byte[]]@()) }',
);

/// Creates directory [path] and any missing parents (`mkdir -p`).
String windowsCreateDirectoryScript(String path) =>
    _psTry('[void][IO.Directory]::CreateDirectory(${_psq(path)})');
