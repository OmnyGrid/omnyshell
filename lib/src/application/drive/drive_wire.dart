/// Wire protocol for OmnyDrive sessions (`SessionMode.drive`).
///
/// A drive session is a long-lived request/response channel: the client issues
/// content and git operations against a node-side path, and the node replies.
/// Unlike an exec session, there is no process — the node's drive service
/// translates each request into a filesystem or git operation.
///
/// Messages ride the channel's raw byte streams (client requests on stdin, node
/// responses on stdout), framed as:
///
/// ```
/// [uint32 bodyLen][uint32 headerLen][header JSON utf8][payload bytes]
/// ```
///
/// The header is a small JSON map (the operation, its arguments, and a
/// correlation `id`); the payload carries opaque bytes (file contents). This
/// mirrors the framed approach used by the file-transfer service, so the same
/// flow-control credit window applies.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:omnydrive/omnydrive.dart' show ContentCompression;

/// Header key flagging that a [DriveMessage]'s payload is gzip-encoded and must
/// be inflated by the receiver. Absent (or `false`) means the payload is raw.
const String kDriveGzipFlag = 'gz';

/// Shared gzip policy for drive payloads, reusing omnydrive's transport-agnostic
/// [ContentCompression]. Both the client ([DriveRpcClient]) and the node
/// ([NodeDriveService]) compress at their sending edge and inflate at their
/// receiving edge, signalling per message via [kDriveGzipFlag].
///
/// omnyshell carries drive content over its own [DriveMessage] channel rather
/// than omnydrive's HTTP transport, so the HTTP layer's automatic gzip never
/// applies here — this helper brings the same saving to the channel transport.
class DriveCompression {
  DriveCompression._();

  /// The active policy: gzip level 4, skip payloads < 1 KiB and already-
  /// compressed file types (jpeg, png, mp4, zip, …).
  static final ContentCompression policy = ContentCompression.standard;

  /// Compresses [bytes] when worthwhile under [policy], returning the payload to
  /// put on the wire and whether it was gzipped (the value for [kDriveGzipFlag]).
  ///
  /// Pass the file [path] for content reads/writes so the extension/size gates
  /// apply; pass `null` for path-less payloads (e.g. the JSON manifest), gating
  /// on size alone.
  static (Uint8List payload, bool gzipped) encodePayload(
    String? path,
    List<int> bytes,
  ) {
    final compress = path == null
        ? policy.shouldCompressBytes(bytes.length)
        : policy.shouldCompress(path, bytes.length);
    if (!compress) {
      return (Uint8List.fromList(bytes), false);
    }
    return (Uint8List.fromList(policy.encode(bytes)), true);
  }

  /// Inflates [payload] when [header] flags it gzipped, otherwise returns it
  /// unchanged. The flag is authoritative: the sender sets it exactly when it
  /// gzipped the payload, so a verbatim payload is never decoded even if its
  /// first bytes happen to match the gzip magic number.
  static List<int> decodePayload(
    Map<String, dynamic> header,
    Uint8List payload,
  ) {
    return header[kDriveGzipFlag] == true
        ? ContentCompression.decode(payload)
        : payload;
  }
}

/// Operation names carried in a [DriveMessage] request header under `op`.
class DriveOp {
  /// Build and return the manifest of the served directory.
  static const manifest = 'manifest';

  /// Read the bytes of a file (`path`); reply payload carries the bytes.
  static const read = 'read';

  /// Write the request payload to a file (`path`).
  static const write = 'write';

  /// Delete a file (`path`).
  static const delete = 'delete';

  /// Clone a git repository (`url`, optional `branch`/`depth`/`bare`) into the
  /// served path; reply header carries the resulting `head` SHA.
  static const gitClone = 'git.clone';

  /// Synchronize the served git working tree (`direction`, `baseline`); reply
  /// header carries `head`, `applied`, optional `publishedBranch`/`conflict`.
  static const gitSync = 'git.sync';

  /// Return the current git `head` SHA of the served path.
  static const gitHead = 'git.head';
}

/// Keys used in the [SessionOpen] `env` map to parametrize a drive session.
class DriveEnv {
  /// `dir` or `git` — which provider serves the path.
  static const kind = 'driveKind';

  /// `1` when the mount is read-write, `0` for read-only.
  static const readWrite = 'driveRw';

  /// JSON (`jsonEncode` of `PathFilter.toJson()`) restricting which sub-paths a
  /// `dir` drive serves; absent when the mount has no filter. The node applies
  /// it to every manifest/read/write/delete so excluded files are never served.
  static const filter = 'driveFilter';

  /// `dir` kind value.
  static const kindDir = 'dir';

  /// `git` kind value.
  static const kindGit = 'git';
}

/// One framed drive message: a JSON [header] plus an optional binary [payload].
class DriveMessage {
  /// The decoded JSON header (operation/result metadata + correlation `id`).
  final Map<String, dynamic> header;

  /// The opaque binary payload (file bytes), empty when none.
  final Uint8List payload;

  /// Creates a drive message.
  DriveMessage(this.header, [Uint8List? payload])
    : payload = payload ?? Uint8List(0);

  /// The correlation id linking a response to its request.
  int get id => (header['id'] as num).toInt();

  /// The operation name (requests only).
  String? get op => header['op'] as String?;

  /// Whether a response reports success.
  bool get ok => header['ok'] == true;

  /// The error message on a failed response, if any.
  String? get error => header['error'] as String?;

  /// Encodes this message to its on-wire byte form.
  Uint8List encode() {
    final headerBytes = utf8.encode(jsonEncode(header));
    final bodyLen = 4 + headerBytes.length + payload.length;
    final out = Uint8List(4 + bodyLen);
    final view = ByteData.view(out.buffer);
    view.setUint32(0, bodyLen);
    view.setUint32(4, headerBytes.length);
    out.setRange(8, 8 + headerBytes.length, headerBytes);
    out.setRange(8 + headerBytes.length, out.length, payload);
    return out;
  }

  /// Builds a request message for [op] with [id], header [fields] and [payload].
  factory DriveMessage.request(
    int id,
    String op, {
    Map<String, dynamic> fields = const {},
    Uint8List? payload,
  }) => DriveMessage({'id': id, 'op': op, ...fields}, payload);

  /// Builds a success response for request [id] with header [fields] and an
  /// optional [payload].
  factory DriveMessage.ok(
    int id, {
    Map<String, dynamic> fields = const {},
    Uint8List? payload,
  }) => DriveMessage({'id': id, 'ok': true, ...fields}, payload);

  /// Builds an error response for request [id].
  factory DriveMessage.err(int id, String message) =>
      DriveMessage({'id': id, 'ok': false, 'error': message});
}

/// Incrementally reassembles [DriveMessage]s from a byte stream.
///
/// Feed inbound chunks via [add]; each call returns any messages that became
/// complete. Partial frames are retained until the rest of their bytes arrive.
class DriveFrameReader {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  /// Appends [chunk] and returns the messages now fully available.
  List<DriveMessage> add(List<int> chunk) {
    // Merge any retained bytes with the new chunk into a single contiguous view.
    if (_pending.isNotEmpty) {
      _buffer.add(_pending);
      _pending = Uint8List(0);
    }
    _buffer.add(chunk);
    var data = _buffer.takeBytes();
    final out = <DriveMessage>[];
    var offset = 0;
    while (data.length - offset >= 4) {
      final view = ByteData.view(data.buffer, data.offsetInBytes + offset);
      final bodyLen = view.getUint32(0);
      if (data.length - offset - 4 < bodyLen) break; // wait for more bytes
      final bodyStart = offset + 4;
      final headerLen = ByteData.view(
        data.buffer,
        data.offsetInBytes + bodyStart,
      ).getUint32(0);
      final headerStart = bodyStart + 4;
      final headerEnd = headerStart + headerLen;
      final payloadEnd = bodyStart + bodyLen;
      final header =
          jsonDecode(utf8.decode(data.sublist(headerStart, headerEnd)))
              as Map<String, dynamic>;
      final payload = Uint8List.sublistView(data, headerEnd, payloadEnd);
      out.add(DriveMessage(header, Uint8List.fromList(payload)));
      offset = payloadEnd;
    }
    // Retain whatever remains of a partial frame for the next [add].
    if (offset < data.length) {
      _pending = Uint8List.fromList(data.sublist(offset));
    }
    return out;
  }
}
