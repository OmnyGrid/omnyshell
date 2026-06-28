@TestOn('!windows')
library;

import 'dart:io';

import 'package:test/test.dart';

/// Runs `omnyshell <args>` through the Dart VM and returns the process result.
Future<ProcessResult> _omnyshell(List<String> args, {String? dataHome}) =>
    Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/omnyshell.dart', ...args],
      // Point the service registry at an isolated, empty data dir so
      // info/reinstall see "not installed" regardless of the host's state.
      environment: dataHome == null
          ? null
          : {'HOME': dataHome, 'XDG_DATA_HOME': dataHome},
    );

void main() {
  group('service install --dry-run', () {
    test(
      'hub renders the role command with absolute paths and grants',
      () async {
        final r = await _omnyshell([
          'service',
          'install',
          'hub',
          '--cert',
          '/tmp/hub.crt',
          '--key',
          '/tmp/hub.key',
          '--port',
          '9443',
          '--grant-token',
          'alice:s3cret:admin',
          '--dry-run',
        ]);
        expect(r.exitCode, 0, reason: r.stderr.toString());
        final out = r.stdout.toString();
        // The baked-in service command runs `omnyshell hub start …`.
        expect(out, contains('hub'));
        expect(out, contains('start'));
        // Path-valued flags are absolutized; values are passed through.
        expect(out, contains('/tmp/hub.crt'));
        expect(out, contains('/tmp/hub.key'));
        expect(out, contains('9443'));
        expect(out, contains('alice:s3cret:admin'));
        // Dry-run must not touch the system.
        expect(out, isNot(contains('Installed and started')));
      },
    );

    test('hub renders --tls-dir as an absolute path', () async {
      final dir = Directory.systemTemp.createTempSync('tls_dir_render');
      File('${dir.path}/fullchain.pem').writeAsStringSync('x');
      File('${dir.path}/privkey.pem').writeAsStringSync('x');
      addTearDown(() => dir.deleteSync(recursive: true));

      final r = await _omnyshell([
        'service',
        'install',
        'hub',
        '--tls-dir',
        dir.path,
        '--grant-token',
        'alice:s3cret:admin',
        '--dry-run',
      ]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final out = r.stdout.toString();
      expect(out, contains('start'));
      expect(out, contains('--tls-dir'));
      expect(out, contains(File(dir.path).absolute.path));
      // No certificate flags are emitted in directory mode.
      expect(out, isNot(contains('--cert')));
    });

    test('node renders connection + node options', () async {
      final r = await _omnyshell([
        'service',
        'install',
        'node',
        '--id',
        'worker-01',
        '--principal',
        'node-acct',
        '--token',
        'NODETOK',
        '--hub',
        'wss://hub.example:8443',
        '--label',
        'env=prod',
        '--dry-run',
      ]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final out = r.stdout.toString();
      expect(out, contains('node'));
      expect(out, contains('worker-01'));
      expect(out, contains('wss://hub.example:8443'));
      expect(out, contains('env=prod'));
    });
  });

  group('service install validation', () {
    test('hub without --key fails', () async {
      final r = await _omnyshell([
        'service',
        'install',
        'hub',
        '--cert',
        '/tmp/hub.crt',
        '--grant-token',
        'a:b:admin',
      ]);
      expect(r.exitCode, isNonZero);
      expect(r.stderr.toString(), contains('--cert and --key are required'));
    });

    test('hub with both --tls-dir and --cert fails', () async {
      final dir = Directory.systemTemp.createTempSync('tls_dir_both');
      File('${dir.path}/fullchain.pem').writeAsStringSync('x');
      File('${dir.path}/privkey.pem').writeAsStringSync('x');
      addTearDown(() => dir.deleteSync(recursive: true));

      final r = await _omnyshell([
        'service',
        'install',
        'hub',
        '--tls-dir',
        dir.path,
        '--cert',
        '/tmp/hub.crt',
        '--grant-token',
        'a:b:admin',
      ]);
      expect(r.exitCode, isNonZero);
      expect(
        r.stderr.toString(),
        contains('use either --tls-dir or --cert/--key'),
      );
    });

    test('hub --tls-dir without the pem files fails', () async {
      final dir = Directory.systemTemp.createTempSync('tls_dir_empty');
      addTearDown(() => dir.deleteSync(recursive: true));

      final r = await _omnyshell([
        'service',
        'install',
        'hub',
        '--tls-dir',
        dir.path,
        '--grant-token',
        'a:b:admin',
      ]);
      expect(r.exitCode, isNonZero);
      expect(
        r.stderr.toString(),
        contains('must contain fullchain.pem and privkey.pem'),
      );
    });

    test('node without credentials fails', () async {
      final r = await _omnyshell(['service', 'install', 'node', '--id', 'w1']);
      expect(r.exitCode, isNonZero);
      expect(r.stderr.toString(), contains('--principal'));
    });

    test('unknown role fails', () async {
      final r = await _omnyshell([
        'service',
        'install',
        'gateway',
        '--dry-run',
      ]);
      expect(r.exitCode, isNonZero);
      expect(r.stderr.toString(), contains('unknown role'));
    });
  });

  group('service info / reinstall', () {
    late Directory dataHome;
    setUp(() => dataHome = Directory.systemTemp.createTempSync('svc_info'));
    tearDown(() => dataHome.deleteSync(recursive: true));

    test('info on a service that is not installed reports it', () async {
      final r = await _omnyshell([
        'service',
        'info',
        'node',
      ], dataHome: dataHome.path);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout.toString(), contains('node: not installed'));
    });

    test(
      'reinstall with no options on a missing service fails clearly',
      () async {
        final r = await _omnyshell([
          'service',
          'reinstall',
          'hub',
        ], dataHome: dataHome.path);
        expect(r.exitCode, isNonZero);
        expect(r.stderr.toString(), contains('is not installed'));
      },
    );

    test('reinstall --dry-run (override) renders the role command', () async {
      final r = await _omnyshell([
        'service',
        'reinstall',
        'hub',
        '--cert',
        '/tmp/hub.crt',
        '--key',
        '/tmp/hub.key',
        '--grant-token',
        'alice:s3cret:admin',
        '--dry-run',
      ], dataHome: dataHome.path);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final out = r.stdout.toString();
      expect(out, contains('hub'));
      expect(out, contains('start'));
      expect(out, contains('/tmp/hub.crt'));
      expect(out, isNot(contains('Reinstalled')));
    });
  });
}
