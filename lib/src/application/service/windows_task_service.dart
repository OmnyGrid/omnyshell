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
    final log = logPathFor(d);
    Directory(File(log).parent.path).createSync(recursive: true);

    // Best-effort removal of a prior, broken SCM registration from the old
    // code path so the two backends do not collide.
    await _run('sc.exe', ['delete', _scmName(d.serviceName)]);

    final xml = buildTaskXml(d, logPath: log, currentUser: _currentUser());
    final tmp = File(
      '${Directory.systemTemp.createTempSync('omnyshell_task').path}'
      '${Platform.pathSeparator}$xmlBasename',
    )..writeAsStringSync(xml);
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
    final tn = taskName(d.serviceName);
    final xml = buildTaskXml(
      d,
      logPath: logPathFor(d),
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

  /// Resolves the log file path: under `OMNYSHELL_HOME` when the descriptor sets
  /// it, else `%LOCALAPPDATA%\OmnyShell\<role>.log`.
  String logPathFor(svc.ServiceDescriptor d) {
    final home = d.environment['OMNYSHELL_HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home\\${d.serviceName}.log';
    }
    final local =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return '$local\\OmnyShell\\${d.serviceName}.log';
  }
}

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
/// System scope runs at boot as `LocalSystem` (`S-1-5-18`) with elevation;
/// user scope runs at logon for [currentUser] with an interactive token. The
/// action is wrapped in `cmd.exe /c` so `OMNYSHELL_HOME` can be set inline
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
            '<LogonType>InteractiveToken</LogonType>'
            '<RunLevel>LeastPrivilege</RunLevel>';

  return '''
<?xml version="1.0" encoding="UTF-8"?>
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
