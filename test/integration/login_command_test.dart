@TestOn('!windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// Drives the real `omnyshell login` command as a child process against an
/// isolated `OMNYSHELL_HOME`, so the credential file it reads and writes is the
/// test's own. The session-management half (`--list`, picking the default Hub)
/// needs no Hub; `login validate` is exercised against a live [TestCluster],
/// including the failures it exists to report — a rejected token, an
/// unreachable Hub and a certificate the client does not trust.
void main() {
  late Directory snapshotDir;
  late String snapshot;
  late Directory tmp;
  late String home;

  /// The CA that the test Hub's self-signed certificate is its own issuer of.
  const ca = 'test/support/certs/localhost.crt';

  setUpAll(() async {
    // One kernel snapshot for the whole group: `dart run` would recompile the
    // CLI for each of the ~25 invocations below.
    snapshotDir = Directory.systemTemp.createTempSync('omnyshell-login-cli');
    snapshot = '${snapshotDir.path}/omnyshell.dill';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'bin/omnyshell.dart',
      '-o',
      snapshot,
    ]);
    expect(compiled.exitCode, 0, reason: compiled.stderr.toString());
  });

  tearDownAll(() => snapshotDir.deleteSync(recursive: true));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('omnyshell-login-home');
    home = tmp.path;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProcessResult> omnyshell(List<String> args) => Process.run(
    Platform.resolvedExecutable,
    [snapshot, ...args],
    environment: {'OMNYSHELL_HOME': home},
  );

  /// Writes [sessions] to the credential file the CLI will read, with [$default]
  /// (when given) as the remembered default Hub.
  Future<void> saveSessions(
    Map<String, StoredSession> sessions, {
    String? $default,
  }) => CredentialStore(
    defaultHub: $default,
    sessions: sessions,
  ).save(home: home);

  Future<CredentialStore> reload() => CredentialStore.load(home: home);

  StoredSession token(String principal, {String? ca}) =>
      StoredSession.token(principal: principal, token: 's3cr3t', ca: ca);

  /// Two saved sessions with the localhost one as the default.
  Future<void> saveTwo() => saveSessions({
    'wss://localhost:8443/shell': token('alice'),
    'wss://foo.example.com:8080': token('joe'),
  }, $default: 'wss://localhost:8443/shell');

  group('login --list', () {
    test('says so when nothing is saved', () async {
      final r = await omnyshell(['login', '--list']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, contains('No saved sessions.'));
    });

    test('lists every session and marks the default', () async {
      await saveTwo();
      final r = await omnyshell(['login', '--list']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final out = r.stdout as String;
      expect(out, contains('* wss://localhost:8443/shell  alice (token)'));
      expect(out, contains('  wss://foo.example.com:8080  joe (token)'));
      // The non-default row is not marked.
      expect(out, isNot(contains('* wss://foo.example.com:8080')));
    });
  });

  group('login picks the default Hub', () {
    test('without saved sessions it still asks for credentials', () async {
      final r = await omnyshell(['login']);
      expect(r.exitCode, 1);
      expect(
        r.stderr,
        contains('provide --principal and --token (or --key) to log in'),
      );
    });

    test('with no terminal to prompt on, it lists the sessions', () async {
      await saveTwo();
      final r = await omnyshell(['login']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, contains('Saved Hub sessions'));
      expect(r.stdout, contains('Pass --hub <url> to make one of them'));
      // Listing is not choosing.
      expect((await reload()).defaultHub, 'wss://localhost:8443/shell');
    });

    test('--hub adopts a saved session named by a fragment', () async {
      await saveTwo();
      final r = await omnyshell(['login', '--hub', 'foo.example']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(
        r.stdout,
        contains('Default Hub is now wss://foo.example.com:8080 (joe).'),
      );
      expect((await reload()).defaultHub, 'wss://foo.example.com:8080');
    });

    test('--hub matches the same URL written differently', () async {
      await saveTwo();
      final r = await omnyshell([
        'login',
        '--hub',
        'WSS://Foo.Example.com:8080/',
      ]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect((await reload()).defaultHub, 'wss://foo.example.com:8080');
    });

    test('--hub naming the current default is a no-op', () async {
      await saveTwo();
      final r = await omnyshell([
        'login',
        '--hub',
        'wss://localhost:8443/shell',
      ]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, contains('Default Hub is already'));
      expect((await reload()).defaultHub, 'wss://localhost:8443/shell');
    });

    test('an unknown Hub fails and lists what is saved', () async {
      await saveTwo();
      final r = await omnyshell(['login', '--hub', 'wss://nope:1234']);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('no saved session for wss://nope:1234'));
      expect(r.stderr, contains('wss://foo.example.com:8080'));
      expect(r.stderr, contains('omnyshell login --hub wss://nope:1234'));
      expect((await reload()).defaultHub, 'wss://localhost:8443/shell');
    });

    test('an ambiguous fragment fails with its candidates', () async {
      await saveSessions({
        'wss://foo.example.com:8080': token('joe'),
        'wss://foo.example.com:9090': token('joe'),
      });
      final r = await omnyshell(['login', '--hub', 'foo.example']);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('matches 2 saved sessions'));
      expect(r.stderr, contains('wss://foo.example.com:8080'));
      expect(r.stderr, contains('wss://foo.example.com:9090'));
      expect((await reload()).defaultHub, isNull);
    });

    test('a --principal the session disagrees with is refused', () async {
      await saveTwo();
      final r = await omnyshell([
        'login',
        '--hub',
        'foo.example',
        '--principal',
        'bob',
      ]);
      expect(r.exitCode, 1);
      expect(
        r.stderr,
        contains('the saved session for wss://foo.example.com:8080 is joe'),
      );
      expect((await reload()).defaultHub, 'wss://localhost:8443/shell');
    });

    test('a --principal the session agrees with switches anyway', () async {
      await saveTwo();
      final r = await omnyshell([
        'login',
        '--hub',
        'foo.example',
        '--principal',
        'joe',
      ]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect((await reload()).defaultHub, 'wss://foo.example.com:8080');
    });
  });

  group('login usage', () {
    test('an unknown subcommand is named', () async {
      final r = await omnyshell(['login', 'bogus']);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('unknown "login" subcommand "bogus"'));
    });

    test('--all without validate says where it belongs', () async {
      await saveTwo();
      final r = await omnyshell(['login', '--all']);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('omnyshell login validate --all'));
    });

    test('validate takes at most one Hub', () async {
      await saveTwo();
      final r = await omnyshell(['login', 'validate', 'a', 'b']);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('at most one Hub URL'));
    });

    test('validate rejects --all together with a Hub', () async {
      await saveTwo();
      final r = await omnyshell(['login', 'validate', '--all', 'foo.example']);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('use either --all or a Hub URL, not both'));
    });

    test('validate with nothing saved says so', () async {
      final r = await omnyshell(['login', 'validate']);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('no saved sessions to check'));
    });

    test('validate reports a key file that is no longer there', () async {
      // Fails building the credentials, before any connection is attempted.
      await saveSessions({
        'wss://127.0.0.1:1': StoredSession.publicKey(
          principal: 'alice',
          keyPath: '$home/gone.seed',
        ),
      }, $default: 'wss://127.0.0.1:1');

      final r = await omnyshell(['login', 'validate']);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('FAILED'));
      expect(r.stdout, contains('gone.seed'));
      expect(r.stderr, contains('did not validate'));
    });

    test('validate with no default Hub asks for one', () async {
      await saveSessions({'wss://foo.example.com:8080': token('joe')});
      final r = await omnyshell(['login', 'validate']);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('no default Hub to check'));
      expect(r.stderr, contains('wss://foo.example.com:8080'));
    });
  });

  group('against a live Hub', () {
    late TestCluster cluster;
    late String hub;

    setUp(() async {
      cluster = await TestCluster.start();
      hub = cluster.hubUri.toString();
    });

    tearDown(() => cluster.dispose());

    test('login saves the session, the CA and the default Hub', () async {
      final r = await omnyshell([
        'login',
        '--hub',
        hub,
        '--principal',
        'alice',
        '--token',
        'admin-token',
        '--ca',
        ca,
      ]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, contains('Logged in to $hub as alice.'));

      final store = await reload();
      expect(store.defaultHub, hub);
      expect(store.sessions[hub]!.principal, 'alice');
      expect(store.sessions[hub]!.token, 'admin-token');
      expect(store.sessions[hub]!.ca, ca);
    });

    test('login refuses credentials the Hub rejects', () async {
      final r = await omnyshell([
        'login',
        '--hub',
        hub,
        '--principal',
        'alice',
        '--token',
        'wrong-token',
        '--ca',
        ca,
      ]);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('login failed'));
      expect((await reload()).sessions, isEmpty);
    });

    test('validate reports the default session and its roles', () async {
      await saveSessions({
        hub: StoredSession.token(
          principal: 'alice',
          token: 'admin-token',
          ca: ca,
        ),
      }, $default: hub);

      final r = await omnyshell(['login', 'validate']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, contains('* $hub  alice  OK (roles: admin)'));
    });

    test('validate reports a token the Hub no longer accepts', () async {
      await saveSessions({
        hub: StoredSession.token(principal: 'alice', token: 'revoked', ca: ca),
      }, $default: hub);

      final r = await omnyshell(['login', 'validate']);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('FAILED'));
      expect(r.stdout, contains('Invalid token'));
      expect(r.stderr, contains('did not validate'));
      // A failed check never rewrites the store.
      expect((await reload()).sessions[hub]!.token, 'revoked');
    });

    test('validate picks the session named as an argument', () async {
      await saveSessions({
        hub: StoredSession.token(
          principal: 'alice',
          token: 'admin-token',
          ca: ca,
        ),
        'wss://127.0.0.1:1': token('ghost'),
      }, $default: hub);

      final r = await omnyshell(['login', 'validate', 'wss://127.0.0.1:1']);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('wss://127.0.0.1:1'));
      expect(r.stdout, contains('FAILED'));
      // The default session was not the one asked about, so it was not checked.
      expect(r.stdout, isNot(contains('OK')));
      expect(r.stderr, contains('did not validate — log in again'));
    });

    test('validate --all checks every session and counts failures', () async {
      await saveSessions({
        hub: StoredSession.token(
          principal: 'alice',
          token: 'admin-token',
          ca: ca,
        ),
        'wss://127.0.0.1:1': token('ghost'),
      }, $default: hub);

      final r = await omnyshell(['login', 'validate', '--all']);
      expect(r.exitCode, 1);
      final out = r.stdout as String;
      expect(out, contains('* $hub  alice  OK (roles: admin)'));
      expect(out, matches(RegExp(r'wss://127\.0\.0\.1:1\s+ghost\s+FAILED')));
      expect(r.stderr, contains('1 of 2 saved sessions did not validate'));
    });

    test('a --ca on the command line overrides the saved one', () async {
      // Saved without a CA: the self-signed Hub certificate does not verify.
      await saveSessions({
        hub: StoredSession.token(principal: 'alice', token: 'admin-token'),
      }, $default: hub);

      final untrusted = await omnyshell(['login', 'validate']);
      expect(untrusted.exitCode, 1);
      expect(untrusted.stdout, contains('FAILED'));
      expect(untrusted.stdout, contains('CERTIFICATE_VERIFY_FAILED'));

      final trusted = await omnyshell(['login', 'validate', '--ca', ca]);
      expect(trusted.exitCode, 0, reason: trusted.stderr.toString());
      expect(trusted.stdout, contains('OK (roles: admin)'));
    });

    test('--insecure-skip-verify on the command line is honoured', () async {
      await saveSessions({
        hub: StoredSession.token(principal: 'alice', token: 'admin-token'),
      }, $default: hub);

      final r = await omnyshell([
        'login',
        'validate',
        '--insecure-skip-verify',
      ]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, contains('OK (roles: admin)'));
      expect(r.stderr, contains('[security] WARNING'));
    });
  });
}
