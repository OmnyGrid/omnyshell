@TestOn('vm')
@Tags(['windows'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:omnyshell/omnyshell_node.dart';
import 'package:omnyshell/src/infrastructure/backend/live_environment.dart';
import 'package:test/test.dart';

/// A node runs for days (as a service), but Windows environment variables are
/// edited in the registry while it runs. New sessions must see those edits, not
/// the snapshot the node process started with.
///
/// These tests edit `HKCU\Environment` *after* this process started, which is
/// exactly the situation: [Platform.environment] cannot see the change, and a
/// session must.
void main() {
  final skip = Platform.isWindows ? null : 'Windows only';
  final nonce = Random().nextInt(1 << 32).toRadixString(16);

  // Before any registry edit, as a node does when it builds its backends: the
  // baseline that tells launcher changes from registry ones.
  setUpAll(primeLiveEnvironment);

  /// Sets a user environment variable in the registry, removed on tear-down.
  Future<void> setUserVar(
    String name,
    String value, {
    String type = 'REG_SZ',
  }) async {
    final r = await Process.run('reg', [
      'add',
      r'HKCU\Environment',
      '/v',
      name,
      '/t',
      type,
      '/d',
      value,
      '/f',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    addTearDown(
      () =>
          Process.run('reg', ['delete', r'HKCU\Environment', '/v', name, '/f']),
    );
  }

  Future<String> execOut(ShellBackend backend, String command) async {
    final session = await backend.start(
      ShellRequest(mode: SessionMode.exec, command: command),
    );
    final out = utf8.decode(
      await session.stdout.expand((e) => e).toList(),
      allowMalformed: true,
    );
    await session.exitCode;
    return out.trim();
  }

  test('reads a user variable set after this process started', () async {
    final name = 'OMNY_LIVE_$nonce';
    await setUserVar(name, 'fresh');
    expect(Platform.environment[name], isNull);
    expect(windowsRegistryEnvironment()?[name], 'fresh');
    expect(liveProcessEnvironment()[name], 'fresh');
  }, skip: skip);

  test('expands a REG_EXPAND_SZ value', () async {
    final name = 'OMNY_EXPAND_$nonce';
    await setUserVar(name, r'%SystemRoot%\omny', type: 'REG_EXPAND_SZ');
    expect(
      liveProcessEnvironment()[name],
      '${Platform.environment['SystemRoot']}\\omny',
    );
  }, skip: skip);

  test('a new exec session sees the new variable', () async {
    final name = 'OMNY_SESSION_$nonce';
    await setUserVar(name, 'in-session');
    final out = await execOut(ProcessShellBackend(), 'echo %$name%');
    expect(out, 'in-session');
  }, skip: skip);

  test('a profile value still overrides the registry', () async {
    final name = 'OMNY_PROFILE_$nonce';
    await setUserVar(name, 'from-registry');
    final backend = ProcessShellBackend(
      baseEnvironment: {name: 'from-profile'},
    );
    expect(await execOut(backend, 'echo %$name%'), 'from-profile');
  }, skip: skip);

  test('a profile PATH reaches the session as its only PATH', () async {
    // The profile spells it `PATH`, the inherited variable `Path`: the child
    // must get one variable, the profile's, not both with `Path` first.
    final dir = await Directory.systemTemp.createTemp('omny_profile_path');
    addTearDown(() => dir.delete(recursive: true));
    final probe = 'omny-profile-probe-$nonce';
    await File(
      '${dir.path}\\$probe.cmd',
    ).writeAsString('@echo via-profile\r\n');
    final backend = ProcessShellBackend(
      baseEnvironmentFor: (inherited) => {
        'PATH': '${dir.path};${inherited['PATH']}',
      },
    );

    expect(await execOut(backend, probe), 'via-profile');
    final vars = (await execOut(backend, 'set')).split(RegExp(r'\r?\n'));
    expect(
      vars.where((l) => l.toUpperCase().startsWith('PATH=')),
      hasLength(1),
    );
  }, skip: skip);

  test(
    'a new session finds a program added to the user PATH',
    () async {
      // A directory holding a probe program, added to the user Path the way
      // an installer would: in the registry, after the node started.
      final dir = await Directory.systemTemp.createTemp('omny_live_path');
      addTearDown(() => dir.delete(recursive: true));
      final probe = 'omny-live-probe-$nonce';
      await File('${dir.path}\\$probe.cmd').writeAsString('@echo found-it\r\n');

      final query = await Process.run('reg', [
        'query',
        r'HKCU\Environment',
        '/v',
        'Path',
      ]);
      final match = RegExp(
        r'Path\s+(REG_\w+)\s+(.*)$',
        multiLine: true,
      ).firstMatch(query.stdout as String);
      final type = match?.group(1) ?? 'REG_EXPAND_SZ';
      final old = match?.group(2)?.trim();
      final r = await Process.run('reg', [
        'add',
        r'HKCU\Environment',
        '/v',
        'Path',
        '/t',
        type,
        '/d',
        old == null || old.isEmpty ? dir.path : '$old;${dir.path}',
        '/f',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      addTearDown(
        () => old == null
            ? Process.run('reg', [
                'delete',
                r'HKCU\Environment',
                '/v',
                'Path',
                '/f',
              ])
            : Process.run('reg', [
                'add',
                r'HKCU\Environment',
                '/v',
                'Path',
                '/t',
                type,
                '/d',
                old,
                '/f',
              ]),
      );

      expect(Platform.environment['PATH'], isNot(contains(dir.path)));
      expect(await execOut(ProcessShellBackend(), probe), 'found-it');
    },
    // Edits the real user Path: only on a throwaway CI runner.
    skip:
        skip ??
        (Platform.environment['CI'] == 'true'
            ? null
            : 'edits the user PATH; set CI=true to run'),
  );
}
