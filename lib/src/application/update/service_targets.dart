/// The `omnyshell` services (hub, node) installed on this machine, and how to
/// act on the ones that need administrator rights.
library;

import 'dart:io';

import 'package:dart_service_manager/dart_service_manager.dart' as svc;

/// An installed `omnyshell` service.
class InstalledService {
  /// `hub` or `node`.
  final String role;
  final svc.ServiceScope scope;

  /// Whether this user's service registry has it. A system service installed
  /// with `sudo` is recorded in root's registry instead, and is found only
  /// by its OS definition; acting on it needs root, whose registry has it.
  final bool registered;

  /// Its live status, when [registered].
  final svc.ServiceStatus? status;

  const InstalledService({
    required this.role,
    required this.scope,
    required this.registered,
    this.status,
  });

  /// Whether changing it needs root/Administrator.
  bool get needsElevation => scope == svc.ServiceScope.system;

  @override
  String toString() =>
      '$role (${scope.name} scope'
      '${status == null ? '' : ', ${status!.name}'})';
}

/// The [roles] of [package] installed as services, from this user's registry
/// ([manager]) and, for system services recorded under another user (root),
/// from the OS definitions: `/etc/systemd/system` (Linux) and
/// `/Library/LaunchDaemons` (macOS). On Windows an Administrator prompt runs
/// as the same user, so the registry already has them.
Future<List<InstalledService>> findInstalledServices(
  svc.DartServiceManager manager, {
  String package = 'omnyshell',
  List<String> roles = const ['hub', 'node'],
  String? operatingSystem,
  bool Function(String path)? exists,
}) async {
  final os = operatingSystem ?? Platform.operatingSystem;
  final fileExists = exists ?? (String path) => File(path).existsSync();
  final found = <InstalledService>[];
  for (final role in roles) {
    try {
      final info = await manager.describe(package, role);
      found.add(
        InstalledService(
          role: role,
          scope: info.entry.scope,
          registered: true,
          status: info.status,
        ),
      );
      continue;
    } on svc.ServiceNotFoundException {
      // Not in this user's registry; maybe a system service root installed.
    } on svc.ServiceManagerException {
      // An unreadable registry: fall through to the OS definition.
    }
    final definition = systemDefinitionPath(package, role, operatingSystem: os);
    if (definition != null && fileExists(definition)) {
      found.add(
        InstalledService(
          role: role,
          scope: svc.ServiceScope.system,
          registered: false,
        ),
      );
    }
  }
  return found;
}

/// Where a system-scope [role] service of [package] is defined on
/// [operatingSystem], or `null` where it is not a file (Windows' Task
/// Scheduler).
String? systemDefinitionPath(
  String package,
  String role, {
  String? operatingSystem,
}) {
  final d = svc.ServiceDescriptor(
    packageName: package,
    serviceName: role,
    executablePath: '',
    scope: svc.ServiceScope.system,
  );
  return switch (operatingSystem ?? Platform.operatingSystem) {
    'linux' => '/etc/systemd/system/${d.systemName}.service',
    'macos' => '/Library/LaunchDaemons/${d.launchdLabel}.plist',
    _ => null,
  };
}

/// [argv] run with administrator rights by asking for them, or `null` where
/// there is no way to ask on this platform:
///
/// - POSIX: `sudo`, which prompts for the password.
/// - Windows: PowerShell's `Start-Process -Verb RunAs`, which shows the UAC
///   prompt and runs [argv] in a new elevated window, waiting for it and
///   passing its exit code on. Its output stays in that window, so the
///   command should write a log ([argv] is expected to).
List<String>? elevatedCommand(List<String> argv, {String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  if (os == 'windows') {
    String ps(String s) => "'${s.replaceAll("'", "''")}'";
    final args = argv.skip(1).map(_windowsArg).join(' ');
    return [
      'powershell',
      '-NoProfile',
      '-Command',
      '\$p = Start-Process -FilePath ${ps(argv.first)} '
          '${args.isEmpty ? '' : '-ArgumentList ${ps(args)} '}'
          '-Verb RunAs -Wait -PassThru; exit \$p.ExitCode',
    ];
  }
  return ['sudo', ...argv];
}

/// [argv] as one command line to show the user (POSIX shell quoting, or
/// Windows quoting on Windows).
String displayCommand(List<String> argv, {String? operatingSystem}) {
  final windows = (operatingSystem ?? Platform.operatingSystem) == 'windows';
  return argv
      .map(
        (a) => windows
            ? _windowsArg(a)
            : (RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(a)
                  ? a
                  : "'${a.replaceAll("'", r"'\''")}'"),
      )
      .join(' ');
}

/// [a] quoted for a Windows command line (`CommandLineToArgvW` rules).
String _windowsArg(String a) {
  if (a.isNotEmpty && !RegExp(r'[\s"]').hasMatch(a)) return a;
  final escaped = a
      .replaceAllMapped(RegExp(r'(\\*)"'), (m) => '${m[1]}${m[1]}\\"')
      .replaceAllMapped(RegExp(r'(\\+)$'), (m) => '${m[1]}${m[1]}');
  return '"$escaped"';
}
