import 'dart:io';

import 'package:dart_service_manager/dart_service_manager.dart' as svc;

/// Runs an external process; injectable so command construction can be unit
/// tested without invoking `schtasks`/`sc`.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Thrown when a `schtasks` lifecycle operation fails.
class WindowsTaskException implements Exception {
  /// A human-readable description of the failure.
  final String message;

  /// Whether the failure looks like a missing-elevation (access denied) error.
  final bool permissionDenied;

  /// Creates a Windows task exception.
  const WindowsTaskException(this.message, {this.permissionDenied = false});

  @override
  String toString() => 'WindowsTaskException: $message';
}

/// Runs the Hub/Node as a **Windows Task Scheduler** task instead of a Service
/// Control Manager service.
///
/// A plain Dart console app cannot perform the in-process SCM handshake
/// (`StartServiceCtrlDispatcher` → `SetServiceStatus`), so registering it as an
/// SCM service yields error 1053 ("did not respond to the start … in time").
/// Task Scheduler runs ordinary console programs as background daemons with no
/// such requirement, so this backend drives `schtasks.exe` to install, control
/// and query a boot/logon-triggered task that auto-restarts on failure.
class WindowsTaskService {
  /// How the process is launched (defaults to [Process.run]).
  final ProcessRunner _run;

  /// Creates a Task Scheduler backend, optionally with a custom [runner].
  WindowsTaskService({ProcessRunner? runner}) : _run = runner ?? Process.run;

  /// Installs (or, with [force], replaces) the task for [d] and optionally
  /// starts it immediately.
  Future<void> install(
    svc.ServiceDescriptor d, {
    bool force = false,
    bool startNow = true,
  }) async {
    final tn = taskName(d.serviceName);

    // Stop any running instance first so its lock on the staged runtime is
    // released and the copy below can overwrite it (best effort: the task may
    // not be installed or running).
    await _run('schtasks.exe', endArgs(tn));

    // Stage a private copy of the runtime so the task does not depend on the
    // volatile, Windows-locked pub-cache snapshot. See [stageRuntime].
    final staged = stageRuntime(d);

    final log = logPathFor(staged);
    Directory(File(log).parent.path).createSync(recursive: true);

    // Best-effort removal of a prior, broken SCM registration from the old
    // code path so the two backends do not collide.
    await _run('sc.exe', ['delete', _scmName(d.serviceName)]);

    final xml = buildTaskXml(staged, logPath: log, currentUser: _currentUser());
    // `schtasks /Create /XML` requires a UTF-16 file; a UTF-8 one fails with
    // "cannot switch encoding".
    final tmp = File(
      '${Directory.systemTemp.createTempSync('omnyshell_task').path}'
      '${Platform.pathSeparator}$xmlBasename',
    )..writeAsBytesSync(encodeUtf16Le(xml));
    try {
      await _check(
        'schtasks.exe',
        createArgs(tn, tmp.path, force: force),
        'create task',
      );
    } finally {
      try {
        tmp.parent.deleteSync(recursive: true);
      } on Object {
        // Temp cleanup is best-effort.
      }
    }
    if (startNow) {
      await _check('schtasks.exe', runArgs(tn), 'start task');
    }
  }

  /// Stops and deletes the task for [role].
  Future<void> uninstall(String role) async {
    final tn = taskName(role);
    await _run('schtasks.exe', endArgs(tn)); // best effort (may not be running)
    await _check('schtasks.exe', deleteArgs(tn), 'delete task');
    cleanStagedRuntime(role);
  }

  /// Starts the installed task for [role].
  Future<void> start(String role) =>
      _check('schtasks.exe', runArgs(taskName(role)), 'start task');

  /// Stops the running task for [role].
  Future<void> stop(String role) =>
      _check('schtasks.exe', endArgs(taskName(role)), 'stop task');

  /// Restarts the task for [role].
  Future<void> restart(String role) async {
    await _run('schtasks.exe', endArgs(taskName(role)));
    await start(role);
  }

  /// Returns a short status word (`running` / `ready` / `disabled` /
  /// `not installed` / `unknown`) for [role].
  Future<String> status(String role) async {
    final res = await _run('schtasks.exe', queryArgs(taskName(role)));
    if (res.exitCode != 0) return 'not installed';
    return parseStatus('${res.stdout}');
  }

  /// Renders the XML and the `schtasks` create command for `--dry-run`.
  String render(svc.ServiceDescriptor d) {
    final staged = stagedDescriptor(d);
    final tn = taskName(staged.serviceName);
    final xml = buildTaskXml(
      staged,
      logPath: logPathFor(staged),
      currentUser: _currentUser(),
    );
    final cmd = [
      'schtasks.exe',
      ...createArgs(tn, '<generated>.xml'),
    ].join(' ');
    return '# Task Scheduler definition for $tn\n$xml\n# Install command:\n$cmd';
  }

  Future<void> _check(String exe, List<String> args, String what) async {
    final res = await _run(exe, args);
    if (res.exitCode != 0) {
      final out = '${res.stderr}'.trim().isNotEmpty
          ? '${res.stderr}'.trim()
          : '${res.stdout}'.trim();
      throw WindowsTaskException(
        'failed to $what (exit ${res.exitCode})'
        '${out.isEmpty ? '' : ': $out'}',
        permissionDenied: out.toLowerCase().contains('access is denied'),
      );
    }
  }

  String? _currentUser() {
    final env = Platform.environment;
    final user = env['USERNAME'];
    if (user == null || user.isEmpty) return null;
    final domain = env['USERDOMAIN'];
    return (domain == null || domain.isEmpty) ? user : '$domain\\$user';
  }

  /// The SCM service name the old `dart_service_manager` path used, cleaned up
  /// on install.
  String _scmName(String role) => 'dart_${_servicePackage}_$role';

  /// The directory holding the service's per-role state: `OMNYSHELL_HOME` when
  /// the descriptor sets it, else `%LOCALAPPDATA%\OmnyShell` (falling back to
  /// `%APPDATA%`, then the system temp dir).
  String serviceHomeDir(svc.ServiceDescriptor d) {
    final home = d.environment['OMNYSHELL_HOME'];
    if (home != null && home.isNotEmpty) return home;
    final local =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return '$local\\OmnyShell';
  }

  /// Resolves the log file path under [serviceHomeDir], e.g.
  /// `%LOCALAPPDATA%\OmnyShell\<role>.log`.
  String logPathFor(svc.ServiceDescriptor d) =>
      '${serviceHomeDir(d)}\\${d.serviceName}.log';

  /// The service-owned directory that holds the staged runtime copy.
  String runtimeDir(svc.ServiceDescriptor d) => '${serviceHomeDir(d)}\\bin';

  /// Whether [d] launches via the Dart VM (`dart <snapshot> …`), as a
  /// `pub global activate` install does — in which case the real program is
  /// `arguments.first` rather than the executable (which is the VM).
  bool _isDartVm(svc.ServiceDescriptor d) {
    final base = _basename(d.executablePath).toLowerCase();
    return (base == 'dart' || base == 'dart.exe') && d.arguments.isNotEmpty;
  }

  /// The path of the runtime file [d] depends on: the snapshot/script for a
  /// Dart-VM (pub-global) launch, else the AOT executable itself.
  String _runtimeSource(svc.ServiceDescriptor d) =>
      _isDartVm(d) ? d.arguments.first : d.executablePath;

  /// Where [stageRuntime] writes the private copy: `<home>\bin\<role>-<file>`.
  String stagedRuntimePath(svc.ServiceDescriptor d) =>
      '${runtimeDir(d)}\\${d.serviceName}-${_basename(_runtimeSource(d))}';

  /// [d] rewritten to launch the staged copy, **without** performing the copy
  /// (used by `--dry-run`). Returns [d] unchanged when it already points at the
  /// staged path.
  svc.ServiceDescriptor stagedDescriptor(svc.ServiceDescriptor d) {
    // Already staged (the runtime lives in our bin dir): leave it untouched so
    // re-staging does not re-prefix the filename.
    if (_samePath(_parentDir(_runtimeSource(d)), runtimeDir(d))) return d;
    final target = stagedRuntimePath(d);
    return _isDartVm(d)
        ? d.copyWith(arguments: [target, ...d.arguments.skip(1)])
        : d.copyWith(executablePath: target);
  }

  /// Copies [d]'s runtime into [runtimeDir] and returns [d] rewritten to launch
  /// that private copy.
  ///
  /// A `dart pub global activate` install runs as `dart <snapshot>`, where the
  /// snapshot lives in the per-SDK pub cache and is **locked by Windows while
  /// the service runs** — so updating omnyshell can't rewrite it, and a later
  /// uninstall+reinstall just re-pins the same stale bytes (the new version
  /// never takes effect). Staging a copy in a service-owned directory decouples
  /// the task from the pub cache: `pub global activate` is then free to rewrite
  /// its snapshot, and every (re)install refreshes this copy from the
  /// currently-running version.
  svc.ServiceDescriptor stageRuntime(svc.ServiceDescriptor d) {
    final rewritten = stagedDescriptor(d);
    if (identical(rewritten, d)) return d; // already staged: nothing to copy
    Directory(runtimeDir(d)).createSync(recursive: true);
    _copyOverwrite(_runtimeSource(d), stagedRuntimePath(d));
    return rewritten;
  }

  /// Best-effort removal of the staged runtime(s) for [role] in the default
  /// (`%LOCALAPPDATA%\OmnyShell\bin`) location; called on uninstall.
  void cleanStagedRuntime(String role) {
    final local =
        Platform.environment['LOCALAPPDATA'] ?? Platform.environment['APPDATA'];
    if (local == null || local.isEmpty) return;
    final dir = Directory('$local\\OmnyShell\\bin');
    if (!dir.existsSync()) return;
    final prefix = '$role-'.toLowerCase();
    for (final f in dir.listSync().whereType<File>()) {
      if (_basename(f.path).toLowerCase().startsWith(prefix)) {
        try {
          f.deleteSync();
        } on Object {
          // May still be locked; leave it for the next install to overwrite.
        }
      }
    }
  }

  /// Copies [source] over [target], retrying briefly: Windows may hold the old
  /// copy locked for a moment after the task that ran it is stopped.
  void _copyOverwrite(String source, String target) {
    for (var attempt = 0; ; attempt++) {
      try {
        File(source).copySync(target);
        return;
      } on FileSystemException {
        if (attempt >= 10) rethrow;
        sleep(const Duration(milliseconds: 200));
      }
    }
  }
}

/// The final path segment of [path], splitting on either separator.
String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

/// The directory portion of [path] (everything before the last separator),
/// or the empty string when [path] has no separator.
String _parentDir(String path) {
  final norm = path.replaceAll('/', '\\');
  final i = norm.lastIndexOf('\\');
  return i < 0 ? '' : norm.substring(0, i);
}

/// Case-insensitive, separator-insensitive path equality (Windows semantics).
bool _samePath(String a, String b) =>
    a.replaceAll('/', '\\').toLowerCase() ==
    b.replaceAll('/', '\\').toLowerCase();

/// The package prefix used in task names and the legacy SCM service name.
const _servicePackage = 'omnyshell';

/// The filename written into the temp dir before `schtasks /Create /XML`.
const xmlBasename = 'omnyshell_task.xml';

/// The Task Scheduler task name (folder + leaf) for [role], e.g.
/// `\OmnyShell\node`.
String taskName(String role) => '\\OmnyShell\\$role';

/// `schtasks` argument vector that imports [xmlPath] as task [tn].
List<String> createArgs(String tn, String xmlPath, {bool force = false}) => [
  '/Create',
  '/TN',
  tn,
  '/XML',
  xmlPath,
  if (force) '/F',
];

/// `schtasks` argument vector to start task [tn] on demand.
List<String> runArgs(String tn) => ['/Run', '/TN', tn];

/// `schtasks` argument vector to stop task [tn].
List<String> endArgs(String tn) => ['/End', '/TN', tn];

/// `schtasks` argument vector to delete task [tn].
List<String> deleteArgs(String tn) => ['/Delete', '/TN', tn, '/F'];

/// `schtasks` argument vector to query task [tn] in verbose list form.
List<String> queryArgs(String tn) => ['/Query', '/TN', tn, '/FO', 'LIST', '/V'];

/// Encodes [s] as UTF-16 little-endian with a leading BOM — the encoding
/// `schtasks /Create /XML` requires (a UTF-8 file is rejected with
/// "cannot switch encoding").
List<int> encodeUtf16Le(String s) {
  final out = <int>[0xFF, 0xFE];
  for (final unit in s.codeUnits) {
    out
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return out;
}

/// Parses the `Status:` field out of `schtasks /Query /FO LIST /V` [output].
String parseStatus(String output) {
  final m = RegExp(r'Status:\s*(\S+)').firstMatch(output);
  if (m == null) return 'unknown';
  switch (m.group(1)!.toLowerCase()) {
    case 'running':
      return 'running';
    case 'ready':
      return 'ready';
    case 'disabled':
      return 'disabled';
    default:
      return 'unknown';
  }
}

/// Builds the Task Scheduler definition XML for [d].
///
/// System scope runs at boot as `LocalSystem` (`S-1-5-18`) with elevation; user
/// scope runs at logon for [currentUser] with an **S4U** token ("run whether the
/// user is logged on or not") so the daemon runs in a non-interactive session —
/// it shows no console window and keeps running after logoff. The action is
/// wrapped in `cmd.exe /c` so `OMNYSHELL_HOME` can be set inline
/// (Task Scheduler has no per-task environment) and stdout/stderr can be
/// appended to [logPath]. The task has no execution time limit (so the daemon
/// is not killed after the default 72 h) and restarts on failure.
String buildTaskXml(
  svc.ServiceDescriptor d, {
  required String logPath,
  String? currentUser,
}) {
  final system = d.scope == svc.ServiceScope.system;
  final args = _commandLine(d, logPath);

  final triggers = system
      ? '<BootTrigger><Enabled>true</Enabled></BootTrigger>'
      : '<LogonTrigger><Enabled>true</Enabled>'
            '${currentUser == null ? '' : '<UserId>${_xml(currentUser)}</UserId>'}'
            '</LogonTrigger>';

  final principal = system
      ? '<UserId>S-1-5-18</UserId>'
            '<RunLevel>HighestAvailable</RunLevel>'
      : '${currentUser == null ? '' : '<UserId>${_xml(currentUser)}</UserId>'}'
            '<LogonType>S4U</LogonType>'
            '<RunLevel>LeastPrivilege</RunLevel>';

  return '''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>${_xml(d.description)}</Description>
  </RegistrationInfo>
  <Triggers>
    $triggers
  </Triggers>
  <Principals>
    <Principal id="Author">
      $principal
    </Principal>
  </Principals>
  <Settings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>9999</Count>
    </RestartOnFailure>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>cmd.exe</Command>
      <Arguments>${_xml(args)}</Arguments>
    </Exec>
  </Actions>
</Task>
''';
}

/// The `cmd.exe` argument string: optional `set OMNYSHELL_HOME`, the quoted
/// executable and its arguments, with output appended to [logPath].
String _commandLine(svc.ServiceDescriptor d, String logPath) {
  final parts = <String>[_cmdQuote(d.executablePath)];
  for (final a in d.arguments) {
    parts.add(_cmdQuote(a));
  }
  parts.add('>> ${_cmdQuote(logPath)} 2>&1');
  var line = parts.join(' ');
  if (d.environment.isNotEmpty) {
    final sets = d.environment.entries
        .map((e) => 'set "${e.key}=${e.value}"')
        .join(' && ');
    line = '$sets && $line';
  }
  return '/c "$line"';
}

/// Quotes [s] for a `cmd.exe` command line when it contains whitespace or shell
/// metacharacters.
String _cmdQuote(String s) {
  if (s.isEmpty) return '""';
  return RegExp(r'[\s&|<>^"]').hasMatch(s) ? '"$s"' : s;
}

/// Escapes the five XML metacharacters in [s].
String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
