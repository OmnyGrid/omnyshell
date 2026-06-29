import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('CwdMarker', () {
    test('command emits the full token but never contains it verbatim', () {
      final marker = CwdMarker('abc');
      expect(marker.command, isNot(contains(marker.token)));
      // The cwd, git, and privilege fields are queried by the marker command.
      expect(marker.command, contains("\"\$PWD\""));
      expect(marker.command, contains('git rev-parse --abbrev-ref HEAD'));
      expect(marker.command, contains('git status --porcelain'));
      expect(marker.command, contains('id -u'));
    });

    test('parses cwd and strips the marker line from output', () {
      final marker = CwdMarker('n1');
      final scan = marker.feed(_b('hello\n${marker.token}/var/www\n'));
      expect(utf8.decode(scan.output), 'hello\n');
      expect(scan.cwd, '/var/www');
      expect(scan.completed, isTrue);
    });

    test('exitCode is null for the regular (4-field) marker', () {
      final marker = CwdMarker('n2');
      final scan = marker.feed(_b('${marker.token}/var/www\t\t\t\n'));
      expect(scan.completed, isTrue);
      expect(scan.exitCode, isNull);
    });

    test(r'agentCommand captures $? and feed() parses the exit-code field', () {
      final marker = CwdMarker('a1');
      expect(marker.agentCommand, isNot(contains(marker.token)));
      expect(marker.agentCommand, contains(r'__omny_ec=$?'));
      // token + cwd, then branch/status/priv/exitcode (a 5th tab field).
      final ok = marker.feed(_b('done\n${marker.token}/srv\t\t\t\t0\n'));
      expect(utf8.decode(ok.output), 'done\n');
      expect(ok.cwd, '/srv');
      expect(ok.exitCode, 0);
      final fail = marker.feed(_b('${marker.token}/srv\tmain\t\troot\t1\n'));
      expect(fail.exitCode, 1);
      expect(fail.branch, 'main');
      expect(fail.privilege, 'root');
    });

    test('pingCommand emits the token but no fields', () {
      final marker = CwdMarker('p1');
      expect(marker.pingCommand, isNot(contains(marker.token)));
      expect(marker.pingCommand, isNot(contains('git')));
      expect(marker.pingCommand, isNot(contains(r'$PWD')));
    });

    test('a ping marker signals completion without changing cwd', () {
      final marker = CwdMarker('p2');
      final scan = marker.feed(_b('output\n${marker.token}\n'));
      expect(utf8.decode(scan.output), 'output\n');
      expect(scan.completed, isTrue);
      expect(scan.cwd, isNull);
      expect(scan.branch, isNull);
    });

    test('a ping with a trailing CRLF is still recognised', () {
      final marker = CwdMarker('p3');
      final scan = marker.feed(_b('${marker.token}\r\n'));
      expect(scan.completed, isTrue);
      expect(scan.cwd, isNull);
    });

    test('parses tab-separated git and privilege fields', () {
      final marker = CwdMarker('g1');
      final scan = marker.feed(
        _b('${marker.token}/srv/app\tmain\t+3 ~2 ?1\troot\n'),
      );
      expect(scan.cwd, '/srv/app');
      expect(scan.branch, 'main');
      expect(scan.gitStatus, '+3 ~2 ?1');
      expect(scan.privilege, 'root');
    });

    test('treats empty git and privilege fields as null', () {
      final marker = CwdMarker('g2');
      final scan = marker.feed(_b('${marker.token}/etc\t\t\t\n'));
      expect(scan.cwd, '/etc');
      expect(scan.branch, isNull);
      expect(scan.gitStatus, isNull);
      expect(scan.privilege, isNull);
    });

    test('parses a clean git repo (branch set, no status)', () {
      final marker = CwdMarker('g3');
      final scan = marker.feed(_b('${marker.token}/srv/app\tmain\t\troot\n'));
      expect(scan.branch, 'main');
      expect(scan.gitStatus, isNull);
      expect(scan.privilege, 'root');
    });

    test('drops the CRLF \\r a PTY adds, keeping the last field clean', () {
      // On a real PTY, ONLCR rewrites the marker's trailing `\n` as `\r\n`. The
      // `\r` must not be captured as part of the trailing (privilege) field.
      final marker = CwdMarker('crlf');
      final scan = marker.feed(
        _b('${marker.token}/srv/app\tmain\t+1 ~0 ?0\t\r\n'),
      );
      expect(scan.cwd, '/srv/app');
      expect(scan.branch, 'main');
      expect(scan.gitStatus, '+1 ~0 ?0');
      // Empty privilege stays null rather than becoming "\r".
      expect(scan.privilege, isNull);
    });

    test('handles a marker split across two chunks', () {
      final marker = CwdMarker('n2');
      final token = marker.token;
      final mid = token.length ~/ 2;

      final first = marker.feed(_b('out${token.substring(0, mid)}'));
      // The partial token is retained, so it is not leaked as output.
      expect(utf8.decode(first.output), 'out');
      expect(first.cwd, isNull);

      final second = marker.feed(_b('${token.substring(mid)}/etc\n'));
      expect(utf8.decode(second.output), isEmpty);
      expect(second.cwd, '/etc');
    });

    test('ping token whole, newline arriving in a separate chunk', () {
      // Regression: winpty scrapes the console and the marker's trailing \n can
      // land in a later 64 KiB read. The complete token must NOT be leaked and
      // the completion signal must still fire once the newline arrives.
      final marker = CwdMarker('w1');
      final first = marker.feed(_b('done${marker.token}'));
      expect(utf8.decode(first.output), 'done'); // token withheld, not leaked
      expect(first.completed, isFalse);

      final second = marker.feed(_b('\n'));
      expect(
        utf8.decode(second.output),
        isEmpty,
      ); // nothing leaks on completion
      expect(second.completed, isTrue);
      expect(second.cwd, isNull);
    });

    test('full token whole, fields and newline arriving in a later chunk', () {
      final marker = CwdMarker('w2');
      final first = marker.feed(_b('${marker.token}/srv'));
      expect(utf8.decode(first.output), isEmpty);
      expect(first.completed, isFalse);
      expect(first.cwd, isNull);

      final second = marker.feed(_b('/app\tmain\t\t\n'));
      expect(utf8.decode(second.output), isEmpty);
      expect(second.completed, isTrue);
      expect(second.cwd, '/srv/app');
      expect(second.branch, 'main');
    });

    test(
      'a terminated marker with a split-token tail still retains the tail',
      () {
        // Guards the else-branch: a chunk with a finished marker AND trailing
        // output ending in a token prefix must consume the marker yet still
        // withhold the partial-token tail.
        final marker = CwdMarker('w3');
        final t = marker.token;
        final mid = t.length ~/ 2;
        final scan = marker.feed(_b('$t/etc\ntail${t.substring(0, mid)}'));
        expect(scan.completed, isTrue);
        expect(scan.cwd, '/etc');
        expect(utf8.decode(scan.output), 'tail'); // partial token tail withheld
      },
    );

    test('two markers in one chunk where the second is unterminated', () {
      final marker = CwdMarker('w4');
      final t = marker.token;
      final first = marker.feed(_b('a\n$t/one\nb\n$t/two'));
      expect(utf8.decode(first.output), 'a\nb\n'); // second token withheld
      expect(first.cwd, '/one'); // only the first (terminated) marker parsed
      final second = marker.feed(_b('\n'));
      expect(second.completed, isTrue);
      expect(second.cwd, '/two');
    });

    test('strips winpty VT escapes the PTY appends to the full marker', () {
      // Real capture: winpty renders the marker line and appends erase-line and
      // cursor-hide sequences before the CRLF. The cwd must come out clean.
      final marker = CwdMarker('probe');
      final scan = marker.feed(
        _b('${marker.token}/c/Users/a7/llama\x1b[0K\x1b[?25l\r\n'),
      );
      expect(scan.completed, isTrue);
      expect(scan.cwd, '/c/Users/a7/llama'); // no escape bytes leak into cwd
      expect(scan.cwd, isNot(contains('\x1b')));
    });

    test(
      'a winpty ping (token wrapped in an erase-line escape) stays a ping',
      () {
        // Real capture: `<token>\x1b[0K\r\n`. The escape must not be mistaken for a
        // cwd field, which would overwrite the cached cwd with garbage.
        final marker = CwdMarker('probe');
        final scan = marker.feed(_b('${marker.token}\x1b[0K\r\n'));
        expect(scan.completed, isTrue);
        expect(scan.cwd, isNull);
        expect(scan.branch, isNull);
      },
    );

    test('strips escapes interleaved with tab-separated fields', () {
      final marker = CwdMarker('g4');
      final scan = marker.feed(
        _b('${marker.token}/srv\x1b[0m\tmain\t+1 ~0 ?0\t\x1b[?25h\r\n'),
      );
      expect(scan.cwd, '/srv');
      expect(scan.branch, 'main');
      expect(scan.gitStatus, '+1 ~0 ?0');
      expect(scan.privilege, isNull); // the trailing escape strips to empty
    });

    test('handles multiple markers in one chunk, keeping the last cwd', () {
      final marker = CwdMarker('n3');
      final t = marker.token;
      final scan = marker.feed(_b('a\n$t/one\nb\n$t/two\n'));
      expect(utf8.decode(scan.output), 'a\nb\n');
      expect(scan.cwd, '/two');
    });

    test('flushes plain output, retaining only a possible-token tail', () {
      final marker = CwdMarker('n4');
      final scan = marker.feed(_b('plain output no marker\n'));
      expect(scan.cwd, isNull);
      // Output is forwarded (a short tail may be retained pending more bytes).
      expect(utf8.decode(scan.output), startsWith('plain output'));
    });
  });
}
