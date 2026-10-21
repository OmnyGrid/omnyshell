import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_service_manager/dart_service_manager.dart' as svc;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnyshell/src/application/update/installation.dart';
import 'package:omnyshell/src/application/update/latest_version.dart';
import 'package:omnyshell/src/application/update/service_targets.dart';
import 'package:test/test.dart';

void main() {
  group('latestHostedVersion', () {
    test('reads latest.version from the repository API', () async {
      Uri? asked;
      final client = MockClient((request) async {
        asked = request.url;
        return http.Response(
          jsonEncode({
            'latest': {'version': '1.64.0'},
          }),
          200,
        );
      });
      expect(
        await latestHostedVersion(
          'omnyshell',
          const HostedSource('https://pub.example.com/'),
          client: client,
        ),
        '1.64.0',
      );
      expect('$asked', 'https://pub.example.com/api/packages/omnyshell');
    });

    test('is null when the repository does not answer in time', () async {
      final client = MockClient(
        (_) => Completer<http.Response>().future, // never answers
      );
      expect(
        await latestHostedVersion(
          'omnyshell',
          const HostedSource('https://pub.dev'),
          client: client,
          timeout: const Duration(milliseconds: 50),
        ),
        isNull,
      );
    });

    test('is null for an answer without a latest version', () async {
      final client = MockClient(
        (_) async => http.Response(jsonEncode({'name': 'omnyshell'}), 200),
      );
      expect(
        await latestHostedVersion(
          'omnyshell',
          const HostedSource('https://pub.dev'),
          client: client,
        ),
        isNull,
      );
    });

    test('is null when the repository cannot tell', () async {
      final client = MockClient((_) async => http.Response('nope', 503));
      expect(
        await latestHostedVersion(
          'omnyshell',
          const HostedSource('https://pub.dev'),
          client: client,
        ),
        isNull,
      );
    });
  });

  test('isNewerVersion follows semver', () {
    expect(isNewerVersion('1.64.0', '1.63.4'), isTrue);
    expect(isNewerVersion('1.63.10', '1.63.9'), isTrue);
    expect(isNewerVersion('1.63.4', '1.63.4'), isFalse);
    expect(isNewerVersion('1.64.0-dev', '1.64.0'), isFalse);
    expect(isNewerVersion('garbage', '1.0.0'), isFalse);
  });

  group('systemDefinitionPath', () {
    test('systemd and launchd system locations', () {
      expect(
        systemDefinitionPath('omnyshell', 'node', operatingSystem: 'linux'),
        '/etc/systemd/system/dart_omnyshell_node.service',
      );
      expect(
        systemDefinitionPath('omnyshell', 'hub', operatingSystem: 'macos'),
        '/Library/LaunchDaemons/com.dartservices.omnyshell.hub.plist',
      );
      expect(
        systemDefinitionPath('omnyshell', 'hub', operatingSystem: 'windows'),
        isNull,
      );
    });
  });

  group('findInstalledServices', () {
    late Directory tmp;
    late svc.DartServiceManager manager;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('omny_services_');
      // An empty registry of this user's: nothing registered.
      manager = svc.DartServiceManager.forCurrentPlatform(
        storagePaths: svc.StoragePaths(
          environment: {
            'HOME': tmp.path,
            'USERPROFILE': tmp.path,
            'LOCALAPPDATA': tmp.path,
            'XDG_DATA_HOME': tmp.path,
          },
        ),
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('finds a system service root installed, by its definition', () async {
      final found = await findInstalledServices(
        manager,
        operatingSystem: 'linux',
        exists: (path) =>
            path == '/etc/systemd/system/dart_omnyshell_node.service',
      );
      expect(found, hasLength(1));
      expect(found.single.role, 'node');
      expect(found.single.scope, svc.ServiceScope.system);
      expect(found.single.registered, isFalse);
      expect(found.single.needsElevation, isTrue);
    });

    test('finds nothing where nothing is installed', () async {
      expect(
        await findInstalledServices(
          manager,
          operatingSystem: 'macos',
          exists: (_) => false,
        ),
        isEmpty,
      );
    });
  }, skip: Platform.isWindows ? 'POSIX service locations' : null);

  group('elevatedCommand', () {
    test('POSIX: sudo', () {
      expect(
        elevatedCommand(['/opt/omnyshell', 'update'], operatingSystem: 'linux'),
        ['sudo', '/opt/omnyshell', 'update'],
      );
    });

    test('Windows: a UAC prompt that waits and passes the exit code on', () {
      final cmd = elevatedCommand([
        r'C:\Program Files\dart\dart.exe',
        r'C:\cache\omnyshell.snapshot',
        'update',
        '--log',
        r'C:\Users\o brien\.omnyshell\update.log',
      ], operatingSystem: 'windows')!;
      expect(cmd.take(3), ['powershell', '-NoProfile', '-Command']);
      final script = cmd.last;
      expect(script, contains(r"-FilePath 'C:\Program Files\dart\dart.exe'"));
      expect(script, contains('-Verb RunAs -Wait -PassThru -ErrorAction Stop'));
      expect(script, contains(r'exit $p.ExitCode'));
      // A declined prompt makes Start-Process fail: never exit 0 for it.
      expect(script, startsWith('try {'));
      expect(script, endsWith('catch { exit $uacDeclinedExitCode }'));
      // Arguments with spaces are quoted for the new process's command line.
      expect(script, contains(r'"C:\Users\o brien\.omnyshell\update.log"'));
    });
  });

  test('windowsCommandLine quotes for CommandLineToArgvW', () {
    expect(
      windowsCommandLine([
        r'C:\Program Files\dart.exe',
        'say "hi"',
        r'C:\dir with space\',
      ]),
      r'"C:\Program Files\dart.exe" "say \"hi\"" "C:\dir with space\\"',
    );
  });

  test('displayCommand quotes what a shell would split', () {
    expect(
      displayCommand([
        'dart',
        'install',
        'omnyshell@{path: /a b}',
      ], operatingSystem: 'linux'),
      "dart install 'omnyshell@{path: /a b}'",
    );
    expect(
      displayCommand([r'C:\a b\dart.exe', 'pub'], operatingSystem: 'windows'),
      r'"C:\a b\dart.exe" pub',
    );
  });
}
