@TestOn('vm && !windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omnydrive/omnydrive.dart'
    show
        AccessMode,
        EndpointId,
        GitCredentialResolver,
        GitProvider,
        GitUserPass,
        LocalPath,
        MountType,
        OriginUri;
import 'package:omnyshell/src/infrastructure/auth/node_git_credentials.dart';
import 'package:test/test.dart';

/// End-to-end: a git drive cloning a **private** remote using a stored
/// credential, exercising the real node path
/// (`NodeGitCredentials` → `resolverFor(principal)` → omnydrive `GitProvider`).
///
/// The remote is a local smart-HTTP git server (`git http-backend`) gated behind
/// HTTP Basic auth, so the clone only succeeds when the credential is actually
/// injected and accepted — proving both the **principal way** and the
/// **global way** resolve and authenticate, and that a missing credential fails.
void main() {
  const username = 'git-user';
  const password = 's3cr3t-token';
  const secret = 'top secret repository contents\n';

  late Directory tmp;
  late _AuthGitHttpServer server;
  late String url;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('omnyshell-gitcred-it');

    // A bare repo with one commit, served over authenticated HTTP.
    final serveRoot = Directory('${tmp.path}/serve')
      ..createSync(recursive: true);
    final work = '${tmp.path}/work';
    await _git(['init', '-q', '-b', 'main', work]);
    File('$work/README.md').writeAsStringSync(secret);
    await _git(['-C', work, 'add', '.']);
    await _git([
      '-C',
      work,
      '-c',
      'user.email=t@example.com',
      '-c',
      'user.name=Test',
      'commit',
      '-q',
      '-m',
      'init',
    ]);
    await _git(['clone', '-q', '--bare', work, '${serveRoot.path}/repo.git']);

    server = await _AuthGitHttpServer.start(
      projectRoot: serveRoot.path,
      username: username,
      password: password,
    );
    // OriginUri host is 127.0.0.1, so credentials are keyed on that host.
    url = 'http://127.0.0.1:${server.port}/repo.git';
  });

  tearDown(() async {
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  /// Clones [url] into a fresh dir via the drive's GitProvider using [resolver],
  /// and returns the cloned working copy's README contents.
  Future<String> cloneWith(GitCredentialResolver? resolver, String name) async {
    final provider = GitProvider(
      endpoint: EndpointId('test-node'),
      credentials: resolver,
    );
    final drive = await provider.describe(
      OriginUri(url),
      accessMode: AccessMode.readOnly,
    );
    final dest = '${tmp.path}/mount-$name';
    await provider.materialize(
      drive: drive,
      dest: LocalPath(dest),
      mountType: MountType.mirror,
    );
    return File('$dest/README.md').readAsStringSync();
  }

  GitUserPass validCredential() =>
      GitUserPass(username: username, password: password);

  test(
    'the private way: a principal-scoped credential clones the remote',
    () async {
      final creds = NodeGitCredentials.empty();
      creds.scopeFor(principal: 'alice').put('127.0.0.1', validCredential());

      // alice authenticates with her own credential.
      expect(await cloneWith(creds.resolverFor('alice'), 'alice'), secret);

      // bob has no credential (and there is no global one) → clone is rejected.
      await expectLater(
        cloneWith(creds.resolverFor('bob'), 'bob'),
        throwsA(anything),
      );
    },
  );

  test(
    'the global way: a node-wide credential clones for any principal',
    () async {
      final creds = NodeGitCredentials.empty();
      creds.scopeFor().put('127.0.0.1', validCredential()); // global scope

      // Any principal falls back to the global credential.
      expect(await cloneWith(creds.resolverFor('anyone'), 'global'), secret);
    },
  );

  test(
    'principal falls back to the global credential for an unregistered host',
    () async {
      // host-x is the served repo (127.0.0.1), registered only GLOBALLY.
      // host-y is a different host for which principal A has its own credential.
      final creds = NodeGitCredentials.empty();
      creds.scopeFor().put('127.0.0.1', validCredential()); // global, host-x
      creds
          .scopeFor(principal: 'alice')
          .put(
            'host-y.example',
            GitUserPass(username: 'host-y-user', password: 'host-y-pass'),
          );

      // Cloning host-x as alice must use the GLOBAL credential — alice's only
      // credential is for host-y and must not be consulted for host-x.
      final resolved =
          creds.resolverFor('alice').resolve(OriginUri(url)) as GitUserPass;
      expect(resolved.username, username); // the global (host-x) credential
      expect(resolved.password, password);

      expect(await cloneWith(creds.resolverFor('alice'), 'fallback'), secret);
    },
  );

  test('no credential fails — the remote really requires auth', () async {
    final creds = NodeGitCredentials.empty();
    await expectLater(
      cloneWith(creds.resolverFor('anyone'), 'none'),
      throwsA(anything),
    );
  });
}

Future<void> _git(List<String> args) async {
  final r = await Process.run('git', args);
  if (r.exitCode != 0) {
    throw StateError(
      'git ${args.join(' ')} failed (${r.exitCode}): ${r.stderr}',
    );
  }
}

/// A minimal smart-HTTP git server that enforces HTTP Basic auth and delegates
/// to `git http-backend` (CGI). Only requests carrying the expected
/// `Authorization: Basic <base64(user:pass)>` header are served; others get 401.
class _AuthGitHttpServer {
  final HttpServer _server;
  final String _projectRoot;
  final String _expectedAuth;

  _AuthGitHttpServer(this._server, this._projectRoot, this._expectedAuth) {
    _server.listen(_handle);
  }

  int get port => _server.port;
  Future<void> close() => _server.close(force: true);

  static Future<_AuthGitHttpServer> start({
    required String projectRoot,
    required String username,
    required String password,
  }) async {
    final expected =
        'Basic ${base64.encode(utf8.encode('$username:$password'))}';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _AuthGitHttpServer(server, projectRoot, expected);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.headers.value(HttpHeaders.authorizationHeader) != _expectedAuth) {
      res
        ..statusCode = HttpStatus.unauthorized
        ..headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="git"');
      await res.close();
      return;
    }

    final body = await _readAll(req);
    final env = <String, String>{
      'GIT_HTTP_EXPORT_ALL': '1',
      'GIT_PROJECT_ROOT': _projectRoot,
      'REQUEST_METHOD': req.method,
      'PATH_INFO': req.uri.path,
      'QUERY_STRING': req.uri.query,
      'CONTENT_TYPE': req.headers.contentType?.toString() ?? '',
      'CONTENT_LENGTH': '${body.length}',
      'REMOTE_USER': 'tester',
    };
    // Forward the wire-protocol version so smart HTTP (v2) negotiates correctly.
    final proto = req.headers.value('git-protocol');
    if (proto != null) env['GIT_PROTOCOL'] = proto;

    final proc = await Process.start('git', ['http-backend'], environment: env);
    proc.stdin.add(body);
    await proc.stdin.close();
    final out = await _readAll(proc.stdout);
    await proc.stderr.drain<void>();
    await proc.exitCode;

    _writeCgiResponse(res, out);
    await res.close();
  }

  /// Splits the CGI output into headers + body, applies the `Status:`/header
  /// lines to [res], and writes the body.
  void _writeCgiResponse(HttpResponse res, List<int> out) {
    final sep = _headerBodyBoundary(out);
    final headerBytes = sep.index < 0 ? out : out.sublist(0, sep.index);
    final bodyBytes = sep.index < 0 ? const <int>[] : out.sublist(sep.end);

    for (final line in utf8.decode(headerBytes).split(RegExp(r'\r?\n'))) {
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final name = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      if (name.toLowerCase() == 'status') {
        res.statusCode = int.tryParse(value.split(' ').first) ?? 200;
      } else {
        res.headers.set(name, value);
      }
    }
    res.add(bodyBytes);
  }

  /// Finds the `\r\n\r\n` (or `\n\n`) that separates CGI headers from the body.
  ({int index, int end}) _headerBodyBoundary(List<int> out) {
    for (var i = 0; i + 3 < out.length; i++) {
      if (out[i] == 13 &&
          out[i + 1] == 10 &&
          out[i + 2] == 13 &&
          out[i + 3] == 10) {
        return (index: i, end: i + 4);
      }
    }
    for (var i = 0; i + 1 < out.length; i++) {
      if (out[i] == 10 && out[i + 1] == 10) return (index: i, end: i + 2);
    }
    return (index: -1, end: -1);
  }

  static Future<List<int>> _readAll(Stream<List<int>> s) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in s) {
      b.add(chunk);
    }
    return b.takeBytes();
  }
}
