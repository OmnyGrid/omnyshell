import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../shared/utils/bytes.dart';

/// Default GZip compression level for transfers (1=fast … 9=best).
const int kDefaultGzipLevel = 4;

/// Max payload of a single `DATA` record (kept under the protocol's 64 KiB data
/// frame so each record maps to at most one wire frame).
const int _chunkSize = 60 * 1024;

/// Sender pauses producing once its outbound backlog exceeds this…
const int _highWater = 512 * 1024;

/// …and resumes once the backlog drains below this.
const int _lowWater = 128 * 1024;

/// The duplex link a transfer runs over.
///
/// Both ends of a transfer speak the same record protocol; this hides whether
/// the underlying bytes travel over a node-side `Channel` or a client-side
/// `RemoteSession`. [send] writes one outbound chunk, [inbound] streams inbound
/// bytes, [grantWindow] replenishes the peer's send credit as bytes are consumed
/// (flow control), and [queuedBytes] reports our own un-flushed backlog so the
/// sender can apply backpressure.
abstract class TransferLink {
  /// Inbound bytes from the peer.
  Stream<Uint8List> get inbound;

  /// Sends [bytes] to the peer.
  void send(List<int> bytes);

  /// Grants the peer [credit] more bytes of send window (flow control).
  void grantWindow(int credit);

  /// Bytes queued locally awaiting send credit (for backpressure).
  int get queuedBytes;
}

// --- Record protocol ---------------------------------------------------------

/// Record type tags for the framed transfer stream. Each record is
/// `[1-byte tag][4-byte big-endian length][payload]`.
class _Rec {
  static const int manifest = 0x01; // sender→receiver: {entries,total}
  static const int resume = 0x02; //   receiver→sender: {have:{path:bytes}}
  static const int entry = 0x03; //    sender→receiver: {path,size,offset}
  static const int data = 0x04; //     sender→receiver: raw gzip bytes
  static const int entryEnd = 0x05; // sender→receiver: {path,sha256}
  static const int done = 0x06; //     sender→receiver: (empty)
  static const int error = 0x07; //    either: utf8 message
}

/// One file in a transfer manifest (path is POSIX-relative to the transfer
/// root; [size] is the uncompressed byte length).
class ManifestEntry {
  /// POSIX-relative path including the transferred top-level name.
  final String path;

  /// Uncompressed size in bytes.
  final int size;

  /// Creates a manifest entry.
  const ManifestEntry(this.path, this.size);

  /// JSON form.
  Map<String, dynamic> toJson() => {'path': path, 'size': size};

  /// Parses a manifest entry.
  static ManifestEntry fromJson(Map<String, dynamic> j) =>
      ManifestEntry(j['path'] as String, (j['size'] as num).toInt());
}

/// Progress notification emitted while a transfer runs.
class TransferProgress {
  /// The entry currently transferring.
  final String currentPath;

  /// Uncompressed bytes transferred so far across all entries.
  final int bytesDone;

  /// Total uncompressed bytes to transfer across all entries.
  final int bytesTotal;

  /// Files fully transferred so far.
  final int filesDone;

  /// Total number of files.
  final int filesTotal;

  /// Creates a progress snapshot.
  const TransferProgress({
    required this.currentPath,
    required this.bytesDone,
    required this.bytesTotal,
    required this.filesDone,
    required this.filesTotal,
  });
}

/// Snapshot handed to a confirmation hook once both ends know the manifest and
/// resume state, but before any file is written or any data flows.
class TransferPreflight {
  /// Every file in the transfer.
  final List<ManifestEntry> entries;

  /// Bytes already present at the destination, per entry path.
  final Map<String, int> have;

  /// Total uncompressed bytes across all entries.
  final int total;

  /// The resolved destination path (a directory to write into, or the explicit
  /// target name when [into] is false).
  final String dest;

  /// Whether the source is written *into* [dest] as a directory (keeping its
  /// top-level name); when false, [dest] names the result itself (rename).
  final bool into;

  /// Creates a preflight snapshot.
  const TransferPreflight({
    required this.entries,
    required this.have,
    required this.total,
    required this.dest,
    required this.into,
  });

  /// The final resolved path where [entryPath] will be written.
  String targetFor(String entryPath) => _mapTarget(dest, into, entryPath);

  /// Entries that already exist in full at the destination (will be re-sent and
  /// verified — i.e. overwritten if content differs).
  List<ManifestEntry> get overwrites => [
    for (final e in entries)
      if ((have[e.path] ?? 0) >= e.size) e,
  ];

  /// Entries present only partially (the transfer will resume them).
  List<ManifestEntry> get resumes => [
    for (final e in entries)
      if ((have[e.path] ?? 0) > 0 && (have[e.path] ?? 0) < e.size) e,
  ];
}

/// The outcome of a completed transfer.
class TransferResult {
  /// Files whose content hash verified successfully.
  final List<String> verified;

  /// Files that failed (hash mismatch or I/O error), path → reason.
  final Map<String, String> failures;

  /// Creates a transfer result.
  const TransferResult({required this.verified, required this.failures});

  /// Whether every entry transferred and verified.
  bool get ok => failures.isEmpty;
}

/// Thrown when the transfer stream ends or is malformed mid-protocol.
class TransferException implements Exception {
  /// The failure detail.
  final String message;

  /// Creates a transfer exception.
  TransferException(this.message);

  @override
  String toString() => 'TransferException: $message';
}

// --- Engine ------------------------------------------------------------------

/// Drives one side of a file transfer over a [TransferLink].
///
/// The protocol is symmetric on the wire: the *sender* (the side reading from
/// disk) emits the manifest then streams each entry as an independent GZip
/// stream from a resume offset, tagged with the source SHA-256; the *receiver*
/// reports resume offsets, decompresses to disk, and verifies each file's hash.
/// Both ends grant flow-control credit as they consume, and the sender throttles
/// on its outbound backlog so memory stays bounded for arbitrarily large files.
class FileTransferEngine {
  final TransferLink _link;
  final _ByteReader _reader;

  /// Creates an engine over [link].
  FileTransferEngine(this._link) : _reader = _ByteReader(_link.inbound);

  /// Runs the sending half: ships [entries] (resolved under [baseDir]) to the
  /// peer, honouring the peer's resume offsets, at GZip [gzipLevel].
  Future<void> runSender({
    required String baseDir,
    required List<ManifestEntry> entries,
    bool single = true,
    int gzipLevel = kDefaultGzipLevel,
    void Function(TransferProgress)? onProgress,
    Future<bool> Function(TransferPreflight)? confirm,
  }) async {
    final total = entries.fold<int>(0, (s, e) => s + e.size);
    _sendRecord(
      _Rec.manifest,
      _json({
        'entries': [for (final e in entries) e.toJson()],
        'total': total,
        'single': single,
      }),
    );

    final resume = await _expect(_Rec.resume);
    final resumeJson = _decode(resume);
    final have = <String, int>{};
    final rawHave = (resumeJson['have'] as Map?) ?? const {};
    rawHave.forEach((k, v) => have[k as String] = (v as num).toInt());

    if (confirm != null &&
        !await confirm(
          TransferPreflight(
            entries: entries,
            have: have,
            total: total,
            // The receiver resolved the destination and reported it back.
            dest: resumeJson['dest'] as String? ?? '',
            into: resumeJson['into'] as bool? ?? true,
          ),
        )) {
      _sendRecord(_Rec.error, _u8(utf8.encode('cancelled by user')));
      return;
    }

    var bytesDone = 0;
    var filesDone = 0;
    for (final entry in entries) {
      var offset = have[entry.path] ?? 0;
      if (offset < 0 || offset > entry.size) offset = 0;
      bytesDone += offset;
      _sendRecord(
        _Rec.entry,
        _json({'path': entry.path, 'size': entry.size, 'offset': offset}),
      );
      onProgress?.call(
        TransferProgress(
          currentPath: entry.path,
          bytesDone: bytesDone,
          bytesTotal: total,
          filesDone: filesDone,
          filesTotal: entries.length,
        ),
      );

      final file = File(
        '$baseDir${Platform.pathSeparator}'
        '${entry.path.replaceAll('/', Platform.pathSeparator)}',
      );
      final hashSink = Sha256().toSync().newHashSink();
      final gzipIn = GZipCodec(
        level: gzipLevel,
      ).encoder.startChunkedConversion(_ChunkSink((c) => _emitData(c)));

      var pos = 0;
      await for (final chunk in file.openRead()) {
        hashSink.add(chunk);
        if (pos + chunk.length > offset) {
          final from = offset > pos ? offset - pos : 0;
          final slice = from == 0
              ? chunk
              : Uint8List.sublistView(_u8(chunk), from);
          gzipIn.add(slice);
          bytesDone += slice.length;
          onProgress?.call(
            TransferProgress(
              currentPath: entry.path,
              bytesDone: bytesDone,
              bytesTotal: total,
              filesDone: filesDone,
              filesTotal: entries.length,
            ),
          );
        }
        pos += chunk.length;
        await _drain();
      }
      gzipIn.close();
      hashSink.close();
      final sha = _hex((await hashSink.hash()).bytes);
      _sendRecord(_Rec.entryEnd, _json({'path': entry.path, 'sha256': sha}));
      filesDone++;
    }
    _sendRecord(_Rec.done, Uint8List(0));
    // Wait until every queued byte has actually been flushed to the wire before
    // returning: the caller closes the channel next, which discards any outbox
    // still awaiting send credit.
    while (_link.queuedBytes > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Runs the receiving half: resolves [dest] (a directory to write into, or an
  /// explicit target name — see [_mapTarget]), recreates the entries' tree,
  /// resumes from any bytes already present, and verifies each file's SHA-256
  /// against the sender's. [destIsDir] forces into-directory mode (the caller's
  /// trailing-separator hint).
  Future<TransferResult> runReceiver({
    required String dest,
    bool destIsDir = false,
    void Function(TransferProgress)? onProgress,
    Future<bool> Function(TransferPreflight)? confirm,
  }) async {
    final manifest = _decode(await _expect(_Rec.manifest));
    final entries = [
      for (final e in (manifest['entries'] as List))
        ManifestEntry.fromJson((e as Map).cast<String, dynamic>()),
    ];
    final total = (manifest['total'] as num).toInt();
    final single = manifest['single'] as bool? ?? true;

    // Resolve how `dest` maps each entry: into an existing/explicit directory,
    // or as a rename target.
    final destType = FileSystemEntity.typeSync(dest, followLinks: true);
    final into =
        destType == FileSystemEntityType.directory ||
        destIsDir ||
        dest.endsWith('/') ||
        dest.endsWith(Platform.pathSeparator);
    if (!into && !single && destType == FileSystemEntityType.file) {
      _sendRecord(
        _Rec.error,
        _u8(
          utf8.encode("Cannot copy a directory onto the existing file '$dest'"),
        ),
      );
      return const TransferResult(
        verified: [],
        failures: {'*': 'destination is a file'},
      );
    }
    File targetOf(String entryPath) => File(_mapTarget(dest, into, entryPath));

    // Resume: report bytes already present at each entry's resolved target.
    final have = <String, int>{};
    var bytesDone = 0;
    for (final e in entries) {
      final f = targetOf(e.path);
      if (f.existsSync()) {
        final len = f.lengthSync();
        final usable = (len > 0 && len <= e.size) ? len : 0;
        if (usable > 0) {
          have[e.path] = usable;
          bytesDone += usable;
        }
      }
    }

    if (confirm != null &&
        !await confirm(
          TransferPreflight(
            entries: entries,
            have: have,
            total: total,
            dest: dest,
            into: into,
          ),
        )) {
      _sendRecord(_Rec.error, _u8(utf8.encode('cancelled by user')));
      return const TransferResult(verified: [], failures: {'*': 'cancelled'});
    }
    _sendRecord(_Rec.resume, _json({'have': have, 'dest': dest, 'into': into}));

    final verified = <String>[];
    final failures = <String, String>{};
    var filesDone = 0;

    RandomAccessFile? raf;
    ByteConversionSink? gunzip;
    File? current;
    String? currentPath;
    final decoded = <Uint8List>[];

    while (true) {
      final (tag, payload) = await _reader.readRecord();
      switch (tag) {
        case _Rec.entry:
          final j = _decode(payload);
          currentPath = j['path'] as String;
          final offset = (j['offset'] as num).toInt();
          current = targetOf(currentPath);
          await current.parent.create(recursive: true);
          raf = await current.open(
            mode: offset > 0 ? FileMode.append : FileMode.write,
          );
          decoded.clear();
          gunzip = GZipCodec().decoder.startChunkedConversion(
            _ChunkSink((c) => decoded.add(_u8(c))),
          );
          _link.grantWindow(payload.length + 5);
          onProgress?.call(
            TransferProgress(
              currentPath: currentPath,
              bytesDone: bytesDone,
              bytesTotal: total,
              filesDone: filesDone,
              filesTotal: entries.length,
            ),
          );
        case _Rec.data:
          gunzip!.add(payload);
          for (final c in decoded) {
            await raf!.writeFrom(c);
            bytesDone += c.length;
          }
          decoded.clear();
          _link.grantWindow(payload.length + 5);
          onProgress?.call(
            TransferProgress(
              currentPath: currentPath ?? '',
              bytesDone: bytesDone,
              bytesTotal: total,
              filesDone: filesDone,
              filesTotal: entries.length,
            ),
          );
        case _Rec.entryEnd:
          gunzip!.close();
          for (final c in decoded) {
            await raf!.writeFrom(c);
            bytesDone += c.length;
          }
          decoded.clear();
          await raf!.flush();
          await raf.close();
          final path = (_decode(payload)['path'] as String);
          final expected = _decode(payload)['sha256'] as String;
          final actual = await _sha256OfFile(current!);
          if (actual == expected) {
            verified.add(path);
          } else {
            // Corrupt/partial: drop it so a re-run fetches it cleanly.
            try {
              await current.delete();
            } on Object {
              /* best effort */
            }
            failures[path] = 'hash mismatch';
          }
          filesDone++;
          raf = null;
          gunzip = null;
          current = null;
          currentPath = null;
          _link.grantWindow(payload.length + 5);
        case _Rec.done:
          _link.grantWindow(5);
          return TransferResult(verified: verified, failures: failures);
        case _Rec.error:
          throw TransferException(utf8.decode(payload, allowMalformed: true));
        default:
          throw TransferException('Unexpected record tag $tag');
      }
    }
  }

  // --- helpers ---------------------------------------------------------------

  void _emitData(List<int> bytes) {
    // Re-chunk compressed output so each DATA record fits one wire frame.
    var off = 0;
    final b = _u8(bytes);
    while (off < b.length) {
      final end = (off + _chunkSize) > b.length ? b.length : off + _chunkSize;
      _sendRecord(_Rec.data, Uint8List.sublistView(b, off, end));
      off = end;
    }
  }

  void _sendRecord(int tag, List<int> payload) {
    final header = Uint8List(5);
    header[0] = tag;
    Bytes.writeUint32(header, 1, payload.length);
    _link.send(header);
    if (payload.isNotEmpty) _link.send(payload);
  }

  Future<Uint8List> _expect(int wantTag) async {
    final (tag, payload) = await _reader.readRecord();
    if (tag == _Rec.error) {
      throw TransferException(utf8.decode(payload, allowMalformed: true));
    }
    if (tag != wantTag) {
      throw TransferException('Expected record $wantTag, got $tag');
    }
    return payload;
  }

  Future<void> _drain() async {
    if (_link.queuedBytes <= _highWater) return;
    while (_link.queuedBytes > _lowWater) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Uint8List _json(Object o) => _u8(utf8.encode(jsonEncode(o)));

  Map<String, dynamic> _decode(List<int> b) =>
      (jsonDecode(utf8.decode(b)) as Map).cast<String, dynamic>();
}

/// Maps a manifest [entryPath] (POSIX-relative, including its top-level name) to
/// a concrete destination path under [dest].
///
/// When [into] is true, [dest] is a directory and the entry keeps its top-level
/// name (`dest/foo/a.txt`). When false, [dest] names the result itself: the
/// entry's first segment is dropped, so a single file maps to exactly [dest] and
/// a directory's contents map directly under [dest] (`cp -r foo dest`).
String _mapTarget(String dest, bool into, String entryPath) {
  if (into) return _join(dest, entryPath);
  final slash = entryPath.indexOf('/');
  final rest = slash < 0 ? '' : entryPath.substring(slash + 1);
  return rest.isEmpty ? dest : _join(dest, rest);
}

String _join(String dir, String rel) {
  final base = dir.endsWith('/') || dir.endsWith(Platform.pathSeparator)
      ? dir.substring(0, dir.length - 1)
      : dir;
  return '$base${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}';
}

// --- File system helpers (shared by callers building manifests) --------------

/// Resolves [sourcePath] into a transfer base directory and manifest entries.
///
/// Entry paths are POSIX-relative to the parent of [sourcePath] and therefore
/// include the transferred top-level name (so `download foo` recreates `foo/…`
/// under the destination, matching `scp -r`). For a single file the manifest has
/// one entry; for a directory it lists every regular file (links not followed).
({String baseDir, List<ManifestEntry> entries, bool single}) buildManifest(
  String sourcePath,
) {
  final type = FileSystemEntity.typeSync(sourcePath, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    throw TransferException('No such file or directory: $sourcePath');
  }
  final entity = type == FileSystemEntityType.directory
      ? Directory(sourcePath).absolute
      : File(sourcePath).absolute;
  final normalized = _stripTrailingSep(entity.path);
  final baseDir = _parentOf(normalized);
  final topName = _baseName(normalized);

  if (type == FileSystemEntityType.directory) {
    final entries = <ManifestEntry>[];
    for (final e in Directory(
      normalized,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path
          .substring(normalized.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      entries.add(ManifestEntry('$topName/$rel', e.lengthSync()));
    }
    return (baseDir: baseDir, entries: entries, single: false);
  }
  return (
    baseDir: baseDir,
    entries: [ManifestEntry(topName, File(normalized).lengthSync())],
    single: true,
  );
}

Future<String> _sha256OfFile(File f) async {
  final sink = Sha256().toSync().newHashSink();
  await for (final chunk in f.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  return _hex((await sink.hash()).bytes);
}

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _u8(List<int> b) => b is Uint8List ? b : Uint8List.fromList(b);

String _stripTrailingSep(String p) {
  var s = p;
  while (s.length > 1 &&
      (s.endsWith('/') || s.endsWith(Platform.pathSeparator))) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

String _baseName(String p) {
  final i = p.lastIndexOf(Platform.pathSeparator);
  final j = p.lastIndexOf('/');
  final cut = i > j ? i : j;
  return cut < 0 ? p : p.substring(cut + 1);
}

String _parentOf(String p) {
  final i = p.lastIndexOf(Platform.pathSeparator);
  final j = p.lastIndexOf('/');
  final cut = i > j ? i : j;
  return cut <= 0 ? p.substring(0, cut + 1) : p.substring(0, cut);
}

/// A [Sink] that forwards each chunk to a callback (for streaming gzip in/out).
class _ChunkSink implements Sink<List<int>> {
  final void Function(List<int>) _onData;
  _ChunkSink(this._onData);
  @override
  void add(List<int> data) => _onData(data);
  @override
  void close() {}
}

/// Pull-based byte reader over an inbound stream: reassembles length-prefixed
/// records that may span or share underlying chunks.
class _ByteReader {
  final Queue<Uint8List> _buffers = Queue();
  int _available = 0;
  Completer<void>? _waiter;
  bool _done = false;
  Object? _error;

  _ByteReader(Stream<Uint8List> stream) {
    stream.listen(
      (chunk) {
        if (chunk.isEmpty) return;
        _buffers.add(chunk);
        _available += chunk.length;
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      cancelOnError: false,
    );
  }

  void _wake() {
    _waiter?.complete();
    _waiter = null;
  }

  Future<(int, Uint8List)> readRecord() async {
    final header = await _readExact(5);
    final len = Bytes.readUint32(header, 1);
    final payload = len == 0 ? Uint8List(0) : await _readExact(len);
    return (header[0], payload);
  }

  Future<Uint8List> _readExact(int n) async {
    while (_available < n) {
      if (_error != null) {
        throw TransferException('Transfer link error: $_error');
      }
      if (_done) {
        throw TransferException('Transfer stream closed mid-record');
      }
      _waiter ??= Completer<void>();
      await _waiter!.future;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final head = _buffers.first;
      final take = (n - filled) < head.length ? (n - filled) : head.length;
      out.setRange(filled, filled + take, head);
      filled += take;
      _buffers.removeFirst();
      if (take != head.length) {
        _buffers.addFirst(Uint8List.sublistView(head, take));
      }
    }
    _available -= n;
    return out;
  }
}
