@TestOn('!windows')
library;

import 'dart:io';

import 'package:test/test.dart';

/// Runs `omnyshell <args>` through the Dart VM and returns the process result.
Future<ProcessResult> _omnyshell(List<String> args) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/omnyshell.dart', ...args],
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
}
