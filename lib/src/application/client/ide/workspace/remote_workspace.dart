import 'dart:convert';

import '../../../../domain/backend/shell_family.dart';
import '../../client_runtime.dart';
import '../ide_command_support.dart' show normalizeRemotePath;
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
/// - On a POSIX node (or a Windows node whose shell is Git Bash): `ls`, `cat`,
///   `touch`, `mkdir`, `test`, and a base64 round-trip for writes.
/// - On a Windows node whose shell is PowerShell or `cmd` ([shellFamily]):
///   PowerShell — present on every Windows — with .NET's file APIs, which take
///   paths literally (no wildcards). Listings and file contents travel as
///   base64 of their UTF-8 bytes, so names and text survive PowerShell's
///   console code page; writes go in chunks that keep each command under
///   Windows' 32K command-line limit. Paths use `/`, which Windows accepts —
///   the same form git reports (see [normalizeRemotePath]).
class RemoteWorkspace implements Workspace {
  RemoteWorkspace({
    required ClientRuntime client,
    required String nodeId,
    required String rootPath,
    ShellFamily? shellFamily,
  }) : _client = client,
       _nodeId = nodeId,
       _shellFamily = shellFamily,
       rootPath = normalizeRemotePath(rootPath),
       commandRunner = RemoteCommandRunner(
         client: client,
         nodeId: nodeId,
         shellFamily: shellFamily,
       );

  final ClientRuntime _client;
  final String _nodeId;
  final ShellFamily? _shellFamily;

  /// Whether file operations go through PowerShell: a Windows node whose
  /// shell is PowerShell or `cmd` (Git Bash takes the POSIX commands).
  bool get _windows =>
      _shellFamily == ShellFamily.powershell || _shellFamily == ShellFamily.cmd;

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

  /// Runs PowerShell [script] on the node (whatever the session's own shell).
  Future<ExecResult> _ps(String script) => _client.execute(
    nodeId: _nodeId,
    command: script,
    shellFamily: ShellFamily.powershell,
  );

  @override
  Future<List<WsEntry>> list(String absPath) async {
    final String listing;
    if (_windows) {
      final r = await _ps(windowsListScript(absPath));
      if (r.exitCode != 0) {
        throw WorkspaceException(
          'cannot list $absPath: ${r.stderrText.trim()}',
        );
      }
      listing = _fromBase64(r.stdoutText);
    } else {
      // `-Ap` lists dotfiles (minus . / ..) and appends `/` to directory names.
      final r = await _run('ls -Ap -- ${_q(absPath)}');
      if (r.exitCode != 0) {
        throw WorkspaceException(
          'cannot list $absPath: ${r.stderrText.trim()}',
        );
      }
      listing = r.stdoutText;
    }
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
    if (_windows) {
      final r = await _ps(windowsReadScript(absPath));
      if (r.exitCode != 0) {
        throw WorkspaceException(
          'cannot read $absPath: ${r.stderrText.trim()}',
        );
      }
      return _fromBase64(r.stdoutText);
    }
    final r = await _run('cat -- ${_q(absPath)}');
    if (r.exitCode != 0) {
      throw WorkspaceException('cannot read $absPath: ${r.stderrText.trim()}');
    }
    return r.stdoutText;
  }

  @override
  Future<void> write(String absPath, String content) async {
    final b64 = base64.encode(utf8.encode(content));
    if (_windows) {
      for (final script in windowsWriteScripts(absPath, b64)) {
        final r = await _ps(script);
        if (r.exitCode != 0) {
          throw WorkspaceException(
            'cannot write $absPath: ${r.stderrText.trim()}',
          );
        }
      }
      return;
    }
    // Decode base64 on the node to avoid any shell-quoting of the content.
    final r = await _run('printf %s ${_q(b64)} | base64 -d > ${_q(absPath)}');
    if (r.exitCode != 0) {
      throw WorkspaceException('cannot write $absPath: ${r.stderrText.trim()}');
    }
  }

  @override
  Future<bool> exists(String absPath) async {
    final r = _windows
        ? await _ps(
            'if (Test-Path -LiteralPath ${_psq(absPath)}) { exit 0 } '
            'else { exit 1 }',
          )
        : await _run('test -e ${_q(absPath)}');
    return r.exitCode == 0;
  }

  @override
  Future<bool> isDirectory(String absPath) async {
    final r = _windows
        ? await _ps(
            'if (Test-Path -LiteralPath ${_psq(absPath)} -PathType Container) '
            '{ exit 0 } else { exit 1 }',
          )
        : await _run('test -d ${_q(absPath)}');
    return r.exitCode == 0;
  }

  @override
  Future<void> createFile(String absPath) async {
    final r = _windows
        ? await _ps(windowsCreateFileScript(absPath))
        : await _run(
            'mkdir -p -- "\$(dirname -- ${_q(absPath)})" && '
            'touch -- ${_q(absPath)}',
          );
    if (r.exitCode != 0) {
      throw WorkspaceException(
        'cannot create $absPath: ${r.stderrText.trim()}',
      );
    }
  }

  @override
  Future<void> createDirectory(String absPath) async {
    final r = _windows
        ? await _ps(
            _psTry('[void][IO.Directory]::CreateDirectory(${_psq(absPath)})'),
          )
        : await _run('mkdir -p -- ${_q(absPath)}');
    if (r.exitCode != 0) {
      throw WorkspaceException(
        'cannot create $absPath: ${r.stderrText.trim()}',
      );
    }
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

/// [s] as a PowerShell single-quoted string literal.
String _psq(String s) => "'${s.replaceAll("'", "''")}'";

/// [body] run so that a failure exits 1 with its message on stderr, and
/// success exits 0 — PowerShell's own exit code says neither reliably.
///
/// The scripts use no double quotes: they reach `powershell.exe` as one
/// `-Command` argument through Windows' command-line quoting, which is where
/// embedded double quotes go wrong.
String _psTry(String body) =>
    "try { \$ErrorActionPreference = 'Stop'; $body; exit 0 } "
    'catch { [Console]::Error.Write(\$_.Exception.Message); exit 1 }';

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

/// The scripts that write [base64] content to file [path]: the first creates
/// or truncates it, the rest append. Each carries at most [chunk] base64
/// characters, keeping it well under Windows' 32,767-character command line.
List<String> windowsWriteScripts(
  String path,
  String base64, {
  int chunk = 16000,
}) {
  assert(chunk % 4 == 0, 'base64 chunks must not split a quantum');
  final scripts = <String>[];
  for (var i = 0; i == 0 || i < base64.length; i += chunk) {
    final part = base64.substring(i, (i + chunk).clamp(0, base64.length));
    scripts.add(
      _psTry(
        '\$b = [Convert]::FromBase64String(\'$part\'); '
        '\$f = [IO.File]::Open(${_psq(path)}, '
        '[IO.FileMode]::${i == 0 ? 'Create' : 'Append'}); '
        'try { \$f.Write(\$b, 0, \$b.Length) } finally { \$f.Dispose() }',
      ),
    );
  }
  return scripts;
}

/// Creates file [path] (and its parent directories) if missing, or updates
/// its modification time — what `mkdir -p … && touch …` does.
String windowsCreateFileScript(String path) => _psTry(
  '\$d = [IO.Path]::GetDirectoryName(${_psq(path)}); '
  'if (\$d) { [void][IO.Directory]::CreateDirectory(\$d) }; '
  'if ([IO.File]::Exists(${_psq(path)})) '
  '{ [IO.File]::SetLastWriteTime(${_psq(path)}, [DateTime]::Now) } '
  'else { [IO.File]::WriteAllBytes(${_psq(path)}, [byte[]]@()) }',
);
