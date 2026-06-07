import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:omnyshell/src/application/transfer/transfer_engine.dart';
import 'package:test/test.dart';

/// An in-memory [TransferLink] paired with [peer]; no credit limit.
class _PipeLink implements TransferLink {
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  late _PipeLink peer;

  @override
  Stream<Uint8List> get inbound => _in.stream;

  @override
  void send(List<int> bytes) => peer._in.add(Uint8List.fromList(bytes));

  @override
  void grantWindow(int credit) {}

  @override
  int get queuedBytes => 0;

  Future<void> dispose() => _in.close();
}

(_PipeLink, _PipeLink) _pair() {
  final a = _PipeLink();
  final b = _PipeLink();
  a.peer = b;
  b.peer = a;
  return (a, b);
}

/// Runs a transfer (sender reads [sourcePath]; receiver resolves [dest]).
Future<TransferResult> _transfer(
  String sourcePath,
  String dest, {
  bool destIsDir = false,
}) async {
  final (a, b) = _pair();
  final manifest = buildManifest(sourcePath);
  final sender = FileTransferEngine(a).runSender(
    baseDir: manifest.baseDir,
    entries: manifest.entries,
    single: manifest.single,
  );
  final receiver = FileTransferEngine(
    b,
  ).runReceiver(dest: dest, destIsDir: destIsDir);
  final result = await receiver;
  // The sender unwinds (throwing) when the receiver rejects/cancels.
  await sender.catchError((Object _) {});
  return result;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('omnytx'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('round-trips a single file and verifies its hash', () async {
    final src = File('${tmp.path}/hello.txt')..writeAsStringSync('hello world');
    final dest = Directory('${tmp.path}/out')..createSync();

    final result = await _transfer(src.path, dest.path);

    expect(result.ok, isTrue);
    expect(result.verified, ['hello.txt']);
    expect(File('${dest.path}/hello.txt').readAsStringSync(), 'hello world');
  });

  test('round-trips a large file (exceeds the credit window)', () async {
    final rnd = Random(7);
    final bytes = Uint8List.fromList(
      List.generate(900 * 1024, (_) => rnd.nextInt(256)),
    );
    final src = File('${tmp.path}/big.bin')..writeAsBytesSync(bytes);
    final dest = Directory('${tmp.path}/out')..createSync();

    final result = await _transfer(src.path, dest.path);

    expect(result.ok, isTrue);
    expect(File('${dest.path}/big.bin').readAsBytesSync(), bytes);
  });

  test('round-trips a directory tree, recreating the layout', () async {
    final root = Directory('${tmp.path}/proj')..createSync();
    File('${root.path}/a.txt').writeAsStringSync('A');
    Directory('${root.path}/sub').createSync();
    File('${root.path}/sub/b.txt').writeAsStringSync('B');
    final dest = Directory('${tmp.path}/out')..createSync();

    final result = await _transfer(root.path, dest.path);

    expect(result.ok, isTrue);
    expect(result.verified.toSet(), {'proj/a.txt', 'proj/sub/b.txt'});
    expect(File('${dest.path}/proj/a.txt').readAsStringSync(), 'A');
    expect(File('${dest.path}/proj/sub/b.txt').readAsStringSync(), 'B');
  });

  test('handles an empty file', () async {
    final src = File('${tmp.path}/empty.txt')..writeAsStringSync('');
    final dest = Directory('${tmp.path}/out')..createSync();

    final result = await _transfer(src.path, dest.path);

    expect(result.ok, isTrue);
    expect(File('${dest.path}/empty.txt').readAsStringSync(), '');
  });

  test('resumes from a partial destination file', () async {
    final full = 'the quick brown fox jumps over the lazy dog' * 5000;
    final src = File('${tmp.path}/data.txt')..writeAsStringSync(full);
    final dest = Directory('${tmp.path}/out')..createSync();
    // Pre-seed a correct partial prefix.
    File('${dest.path}/data.txt').writeAsStringSync(full.substring(0, 1234));

    final result = await _transfer(src.path, dest.path);

    expect(result.ok, isTrue);
    expect(File('${dest.path}/data.txt').readAsStringSync(), full);
  });

  test('detects a hash mismatch and drops the bad file', () async {
    final src = File('${tmp.path}/x.txt')..writeAsStringSync('correct');
    final dest = Directory('${tmp.path}/out')..createSync();
    // A pre-existing file of the SAME size but wrong content: the receiver
    // reports it as complete, the sender sends no bytes, and verification fails.
    File('${dest.path}/x.txt').writeAsStringSync('wrongXX'.substring(0, 7));

    final result = await _transfer(src.path, dest.path);

    expect(result.ok, isFalse);
    expect(result.failures.keys, contains('x.txt'));
    expect(File('${dest.path}/x.txt').existsSync(), isFalse);
  });

  test('honours the confirmation hook (cancel)', () async {
    final src = File('${tmp.path}/c.txt')..writeAsStringSync('data');
    final dest = Directory('${tmp.path}/out')..createSync();
    final (a, b) = _pair();
    final manifest = buildManifest(src.path);
    final sender = FileTransferEngine(
      a,
    ).runSender(baseDir: manifest.baseDir, entries: manifest.entries);
    final result = await FileTransferEngine(
      b,
    ).runReceiver(dest: dest.path, confirm: (_) async => false);
    // The sender observes the cancellation as an error record and unwinds;
    // in production the node's transfer service catches this.
    await sender.catchError((Object _) {});

    expect(result.failures.containsKey('*'), isTrue);
    expect(File('${dest.path}/c.txt').existsSync(), isFalse);
  });

  group('destination resolution', () {
    test(
      'file → explicit new file path (rename) writes exactly that path',
      () async {
        final src = File('${tmp.path}/a.txt')..writeAsStringSync('hi');
        final target = '${tmp.path}/renamed.txt';

        final result = await _transfer(src.path, target);

        expect(result.verified, ['a.txt']);
        expect(File(target).readAsStringSync(), 'hi');
        expect(Directory('${tmp.path}/a.txt').existsSync(), isFalse);
      },
    );

    test('file → existing directory writes dir/<basename>', () async {
      final src = File('${tmp.path}/a.txt')..writeAsStringSync('hi');
      final out = Directory('${tmp.path}/out')..createSync();

      await _transfer(src.path, out.path);

      expect(File('${out.path}/a.txt').readAsStringSync(), 'hi');
    });

    test(
      'file → trailing-slash path (non-existent) treated as directory',
      () async {
        final src = File('${tmp.path}/a.txt')..writeAsStringSync('hi');
        final target = '${tmp.path}/newdir/'; // trailing slash forces into-dir

        await _transfer(src.path, target);

        expect(File('${tmp.path}/newdir/a.txt').readAsStringSync(), 'hi');
      },
    );

    test('directory → non-existent dest becomes the copied root', () async {
      final root = Directory('${tmp.path}/proj')..createSync();
      File('${root.path}/a.txt').writeAsStringSync('A');
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/b.txt').writeAsStringSync('B');
      final target = '${tmp.path}/bar'; // absent, no trailing slash

      final result = await _transfer(root.path, target);

      expect(result.ok, isTrue);
      expect(File('$target/a.txt').readAsStringSync(), 'A');
      expect(File('$target/sub/b.txt').readAsStringSync(), 'B');
      expect(Directory('$target/proj').existsSync(), isFalse);
    });

    test('directory → existing dir nests under <topName>', () async {
      final root = Directory('${tmp.path}/proj')..createSync();
      File('${root.path}/a.txt').writeAsStringSync('A');
      final out = Directory('${tmp.path}/out')..createSync();

      await _transfer(root.path, out.path);

      expect(File('${out.path}/proj/a.txt').readAsStringSync(), 'A');
    });

    test('directory → existing file fails and writes nothing', () async {
      final root = Directory('${tmp.path}/proj')..createSync();
      File('${root.path}/a.txt').writeAsStringSync('A');
      final blocker = File('${tmp.path}/blocker')..writeAsStringSync('keep');

      final result = await _transfer(root.path, blocker.path);

      expect(result.ok, isFalse);
      expect(result.failures.containsKey('*'), isTrue);
      expect(blocker.readAsStringSync(), 'keep'); // untouched
    });
  });

  group('preflight resolution info', () {
    test(
      'into-directory: dest, into and targetFor reflect resolution',
      () async {
        final src = File('${tmp.path}/a.txt')..writeAsStringSync('hi');
        final out = Directory('${tmp.path}/out')..createSync();
        final (a, b) = _pair();
        final m = buildManifest(src.path);
        final sender = FileTransferEngine(
          a,
        ).runSender(baseDir: m.baseDir, entries: m.entries, single: m.single);

        TransferPreflight? seen;
        await FileTransferEngine(b).runReceiver(
          dest: out.path,
          confirm: (pf) async {
            seen = pf;
            return true;
          },
        );
        await sender;

        expect(seen!.into, isTrue);
        expect(seen!.dest, out.path);
        expect(seen!.targetFor('a.txt'), '${out.path}${_sep}a.txt');
      },
    );

    test(
      'rename: targetFor maps the single entry to the dest itself',
      () async {
        final src = File('${tmp.path}/a.txt')..writeAsStringSync('hi');
        final target = '${tmp.path}/renamed.txt';
        final (a, b) = _pair();
        final m = buildManifest(src.path);
        final sender = FileTransferEngine(
          a,
        ).runSender(baseDir: m.baseDir, entries: m.entries, single: m.single);

        TransferPreflight? seen;
        await FileTransferEngine(b).runReceiver(
          dest: target,
          confirm: (pf) async {
            seen = pf;
            return true;
          },
        );
        await sender;

        expect(seen!.into, isFalse);
        expect(seen!.targetFor('a.txt'), target);
      },
    );
  });
}

final String _sep = Platform.pathSeparator;
