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
