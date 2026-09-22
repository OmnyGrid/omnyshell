@TestOn('vm')
library;

import 'package:omnyshell/src/application/client/remote_path.dart';
import 'package:test/test.dart';

void main() {
  group('resolveRemotePath', () {
    test('joins a relative path onto the remote cwd', () {
      expect(resolveRemotePath('log.txt', cwd: '/var/log'), '/var/log/log.txt');
      expect(resolveRemotePath('a/b.txt', cwd: '/srv'), '/srv/a/b.txt');
    });

    test('does not double the separator on a cwd that ends with one', () {
      expect(
        resolveRemotePath('log.txt', cwd: '/var/log/'),
        '/var/log/log.txt',
      );
      expect(resolveRemotePath('x', cwd: '/'), '/x');
    });

    test('leaves an absolute POSIX path alone', () {
      expect(resolveRemotePath('/etc/hosts', cwd: '/srv'), '/etc/hosts');
    });

    test('leaves a home-relative path for the remote shell to expand', () {
      expect(resolveRemotePath('~/notes.md', cwd: '/srv'), '~/notes.md');
      expect(resolveRemotePath('~', cwd: '/srv'), '~');
    });

    test('leaves a Windows drive path alone', () {
      expect(resolveRemotePath(r'C:\Users\a', cwd: '/srv'), r'C:\Users\a');
      expect(resolveRemotePath('d:/data', cwd: '/srv'), 'd:/data');
    });

    test('returns the path as given when the cwd is unknown', () {
      // `?` is what the prompt shows before the first cwd marker arrives.
      expect(resolveRemotePath('log.txt', cwd: null), 'log.txt');
      expect(resolveRemotePath('log.txt', cwd: ''), 'log.txt');
      expect(resolveRemotePath('log.txt', cwd: '?'), 'log.txt');
    });
  });

  group('shQuote', () {
    test('wraps a word so the node takes it literally', () {
      expect(shQuote('plain'), "'plain'");
      expect(shQuote('with space'), "'with space'");
      expect(shQuote(r'$HOME/`whoami`'), r"'$HOME/`whoami`'");
      expect(shQuote(''), "''");
    });

    test('closes and reopens the quote around an embedded quote', () {
      expect(shQuote("it's"), "'it'\\''s'");
    });
  });

  group('remoteBasename', () {
    test('takes the last segment', () {
      expect(remoteBasename('/var/log/syslog'), 'syslog');
      expect(remoteBasename('notes.md'), 'notes.md');
    });

    test('ignores trailing slashes', () {
      expect(remoteBasename('/var/log/'), 'log');
      expect(remoteBasename('/var/log///'), 'log');
    });

    test('falls back to archive for a root or empty path', () {
      expect(remoteBasename('/'), 'archive');
      expect(remoteBasename(''), 'archive');
    });
  });

  group('formatBytes', () {
    test('shows whole bytes without a decimal', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('steps up a unit at each 1024 boundary', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatBytes(1024 * 1024 * 1024 * 1024), '1.0 TB');
    });

    test('stops at terabytes rather than inventing a unit', () {
      expect(formatBytes(4 * 1024 * 1024 * 1024 * 1024), '4.0 TB');
      expect(formatBytes(4096 * 1024 * 1024 * 1024 * 1024), '4096.0 TB');
    });
  });
}
