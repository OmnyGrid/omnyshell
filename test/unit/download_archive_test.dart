import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

/// Runs [command] with `sh -c`, returning the process result.
ProcessResult _sh(String command, {String? cwd}) =>
    Process.runSync('sh', ['-c', command], workingDirectory: cwd);

bool get _hasZip => _sh('command -v zip >/dev/null').exitCode == 0;

void main() {
  group('parseArchiveFlag', () {
    test('maps known flags and aliases', () {
      expect(parseArchiveFlag('--zip'), ArchiveFormat.zip);
      expect(parseArchiveFlag('--gz'), ArchiveFormat.gz);
      expect(parseArchiveFlag('--gzip'), ArchiveFormat.gz);
      expect(parseArchiveFlag('--tar.gz'), ArchiveFormat.tarGz);
      expect(parseArchiveFlag('--tgz'), ArchiveFormat.tarGz);
      expect(parseArchiveFlag('--targz'), ArchiveFormat.tarGz);
    });

    test('returns null for an unknown flag', () {
      expect(parseArchiveFlag('--bz2'), isNull);
      expect(parseArchiveFlag('out.zip'), isNull);
    });
  });

  group('archiveExtension', () {
    test('maps each format to its extension', () {
      expect(archiveExtension(ArchiveFormat.zip), 'zip');
      expect(archiveExtension(ArchiveFormat.gz), 'gz');
      expect(archiveExtension(ArchiveFormat.tarGz), 'tar.gz');
    });
  });

  group('archiveError', () {
    test('files allow gz and zip; reject tar.gz', () {
      expect(archiveError(ArchiveFormat.gz, isDir: false), isNull);
      expect(archiveError(ArchiveFormat.zip, isDir: false), isNull);
      expect(archiveError(ArchiveFormat.tarGz, isDir: false), isNotNull);
    });

    test('directories allow tar.gz and zip; reject gz', () {
      expect(archiveError(ArchiveFormat.tarGz, isDir: true), isNull);
      expect(archiveError(ArchiveFormat.zip, isDir: true), isNull);
      expect(archiveError(ArchiveFormat.gz, isDir: true), isNotNull);
    });
  });

  group('remoteArchiveCommand (executed in sh)', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('arc_test');
      File('${dir.path}/file.txt').writeAsStringSync('single\n');
      Directory('${dir.path}/d/sub').createSync(recursive: true);
      File('${dir.path}/d/a.txt').writeAsStringSync('alpha\n');
      File('${dir.path}/d/sub/b.log').writeAsStringSync('beta\n');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    /// Runs the archive command, asserts success, and returns the temp path.
    String build(String src, ArchiveFormat fmt, bool isDir) {
      final r = _sh(
        remoteArchiveCommand(src, format: fmt, isDir: isDir),
        cwd: dir.path,
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final tmp = (r.stdout as String).trim();
      expect(tmp, isNotEmpty);
      expect(File(tmp).existsSync(), isTrue);
      return tmp;
    }

    test('gz a file round-trips through gunzip', () {
      final tmp = build('file.txt', ArchiveFormat.gz, false);
      final out = _sh('gunzip -c ${_q(tmp)}');
      expect(out.exitCode, 0);
      expect(out.stdout, 'single\n');
      File(tmp).deleteSync();
    });

    test('tar.gz a directory lists its entries', () {
      final tmp = build('d', ArchiveFormat.tarGz, true);
      final list = _sh('tar -tzf ${_q(tmp)}').stdout as String;
      expect(list, contains('d/a.txt'));
      expect(list, contains('d/sub/b.log'));
      File(tmp).deleteSync();
    });

    test('zip a directory lists its entries', () {
      if (!_hasZip) {
        markTestSkipped('zip not installed');
        return;
      }
      final tmp = build('d', ArchiveFormat.zip, true);
      final list = _sh('unzip -l ${_q(tmp)}').stdout as String;
      expect(list, contains('d/a.txt'));
      expect(list, contains('d/sub/b.log'));
      File(tmp).deleteSync();
    });

    test('zip a file stores just the basename', () {
      if (!_hasZip) {
        markTestSkipped('zip not installed');
        return;
      }
      final tmp = build('file.txt', ArchiveFormat.zip, false);
      final list = _sh('unzip -l ${_q(tmp)}').stdout as String;
      expect(list, contains('file.txt'));
      File(tmp).deleteSync();
    });

    test('a missing source exits non-zero and prints nothing', () {
      final r = _sh(
        remoteArchiveCommand(
          'nope.txt',
          format: ArchiveFormat.gz,
          isDir: false,
        ),
        cwd: dir.path,
      );
      expect(r.exitCode, isNot(0));
      expect((r.stdout as String).trim(), isEmpty);
    });

    test('embeds a source name with a space', () {
      File('${dir.path}/a b.txt').writeAsStringSync('spaced\n');
      final tmp = build('a b.txt', ArchiveFormat.gz, false);
      expect((_sh('gunzip -c ${_q(tmp)}').stdout as String), 'spaced\n');
      File(tmp).deleteSync();
    });
  });
}

/// Single-quotes a path for embedding in the verification `sh` commands.
String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";
