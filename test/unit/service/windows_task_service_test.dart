import 'dart:io';

import 'package:dart_service_manager/dart_service_manager.dart' as svc;
import 'package:omnyshell/omnyshell_node.dart';
import 'package:test/test.dart';

svc.ServiceDescriptor _descriptor({
  svc.ServiceScope scope = svc.ServiceScope.system,
  Map<String, String> environment = const {},
  List<String> arguments = const ['node', 'start', '--hub', 'wss://h:8443'],
  String executablePath = r'C:\Program Files\OmnyShell\omnyshell.exe',
}) => svc.ServiceDescriptor(
  packageName: 'omnyshell',
  serviceName: 'node',
  executablePath: executablePath,
  scope: scope,
  arguments: arguments,
  environment: environment,
);

void main() {
  group('taskName', () {
    test('namespaces the role under an OmnyShell folder', () {
      expect(taskName('node'), r'\OmnyShell\node');
      expect(taskName('hub'), r'\OmnyShell\hub');
    });
  });

  group('schtasks argument vectors', () {
    test('create imports the XML and only forces with force', () {
      expect(createArgs(r'\OmnyShell\node', r'C:\t.xml'), [
        '/Create',
        '/TN',
        r'\OmnyShell\node',
        '/XML',
        r'C:\t.xml',
      ]);
      expect(
        createArgs(r'\OmnyShell\node', r'C:\t.xml', force: true),
        contains('/F'),
      );
    });

    test('run/end/delete/query are well-formed', () {
      expect(runArgs(r'\OmnyShell\node'), ['/Run', '/TN', r'\OmnyShell\node']);
      expect(endArgs(r'\OmnyShell\node'), ['/End', '/TN', r'\OmnyShell\node']);
      expect(deleteArgs(r'\OmnyShell\node'), [
        '/Delete',
        '/TN',
        r'\OmnyShell\node',
        '/F',
      ]);
      expect(queryArgs(r'\OmnyShell\node'), [
        '/Query',
        '/TN',
        r'\OmnyShell\node',
        '/FO',
        'LIST',
        '/V',
      ]);
    });
  });

  group('parseStatus', () {
    test('maps the schtasks Status field', () {
      expect(parseStatus('TaskName: x\r\nStatus:    Running\r\n'), 'running');
      expect(parseStatus('Status: Ready'), 'ready');
      expect(parseStatus('Status: Disabled'), 'disabled');
      expect(parseStatus('no status here'), 'unknown');
    });
  });

  group('buildTaskXml', () {
    test('system scope boots as LocalSystem, elevated, with no time limit', () {
      final xml = buildTaskXml(
        _descriptor(),
        logPath: r'C:\log\node.log',
        currentUser: r'CORP\admin',
      );
      expect(xml, contains('<BootTrigger>'));
      expect(xml, contains('<UserId>S-1-5-18</UserId>'));
      expect(xml, contains('<RunLevel>HighestAvailable</RunLevel>'));
      // The daemon must never be killed by the default 72h execution limit.
      expect(xml, contains('<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'));
      expect(xml, contains('<RestartOnFailure>'));
      expect(xml, isNot(contains('<LogonTrigger>')));
    });

    test('user scope triggers at logon and runs hidden via S4U', () {
      final xml = buildTaskXml(
        _descriptor(scope: svc.ServiceScope.user),
        logPath: r'C:\log\node.log',
        currentUser: r'CORP\alice',
      );
      expect(xml, contains('<LogonTrigger>'));
      expect(xml, contains(r'<UserId>CORP\alice</UserId>'));
      // S4U ("run whether logged on or not") runs non-interactively, so no
      // console window appears and the daemon survives logoff.
      expect(xml, contains('<LogonType>S4U</LogonType>'));
      expect(xml, isNot(contains('InteractiveToken')));
      expect(xml, isNot(contains('S-1-5-18')));
    });

    test('action wraps cmd.exe with the exe, args and a log redirect', () {
      final xml = buildTaskXml(
        _descriptor(),
        logPath: r'C:\log\node.log',
        currentUser: null,
      );
      expect(xml, contains('<Command>cmd.exe</Command>'));
      final args = RegExp(
        r'<Arguments>(.*?)</Arguments>',
        dotAll: true,
      ).firstMatch(xml)!.group(1)!;
      expect(args, startsWith('/c '));
      expect(
        args,
        contains('omnyshell.exe'),
      ); // quoted exe (XML-escaped quotes)
      expect(args, contains('node start --hub wss://h:8443'));
      expect(args, contains('&gt;&gt;')); // ">>" redirect, XML-escaped
      expect(args, contains('2&gt;&amp;1')); // "2>&1", XML-escaped
    });

    test('sets OMNYSHELL_HOME inline only when the environment has it', () {
      final without = buildTaskXml(_descriptor(), logPath: r'C:\log\node.log');
      expect(without, isNot(contains('OMNYSHELL_HOME')));

      final with_ = buildTaskXml(
        _descriptor(environment: {'OMNYSHELL_HOME': r'D:\data'}),
        logPath: r'C:\log\node.log',
      );
      expect(with_, contains(r'set &quot;OMNYSHELL_HOME=D:\data&quot;'));
    });

    test('declares UTF-16 (schtasks rejects a UTF-8 file)', () {
      final xml = buildTaskXml(_descriptor(), logPath: r'C:\log\node.log');
      expect(xml, contains('encoding="UTF-16"'));
    });

    test('escapes XML metacharacters in arguments', () {
      final xml = buildTaskXml(
        _descriptor(arguments: const ['node', 'start', '--name', 'a&b<c>']),
        logPath: r'C:\log\node.log',
      );
      expect(xml, contains('a&amp;b&lt;c&gt;'));
      expect(xml, isNot(contains('a&b<c>')));
    });
  });

  group('encodeUtf16Le', () {
    test('prefixes a little-endian BOM and encodes ASCII as 2 bytes', () {
      final bytes = encodeUtf16Le('AB');
      expect(bytes, [0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00]);
    });
  });

  group('lifecycle via injected runner', () {
    test('start invokes schtasks /Run and surfaces failures', () async {
      final calls = <List<String>>[];
      final svcTask = WindowsTaskService(
        runner: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
      );
      await svcTask.start('node');
      expect(calls.single, ['schtasks.exe', '/Run', '/TN', r'\OmnyShell\node']);

      final failing = WindowsTaskService(
        runner: (exe, args) async =>
            ProcessResult(0, 1, '', 'ERROR: Access is denied.'),
      );
      await expectLater(
        failing.start('node'),
        throwsA(
          isA<WindowsTaskException>().having(
            (e) => e.permissionDenied,
            'permissionDenied',
            isTrue,
          ),
        ),
      );
    });

    test('status returns "not installed" when the query fails', () async {
      final task = WindowsTaskService(
        runner: (exe, args) async => ProcessResult(0, 1, '', 'not found'),
      );
      expect(await task.status('node'), 'not installed');
    });
  });
}
