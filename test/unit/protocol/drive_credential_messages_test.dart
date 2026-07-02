import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

/// Round-trips the drive-credential RPC quartet through the frame codec.
void main() {
  final codec = FrameCodec.standard();

  test('DriveCredentialRequest (client→hub) round-trips', () {
    final m = DriveCredentialRequest(
      requestId: 'r1',
      nodeId: 'web-01',
      op: 'add',
      host: 'github.com',
      credential: const {'kind': 'pat', 'username': 'x', 'token': 't'},
    );
    final d =
        codec.decodeControl(codec.encodeControl(m)).message
            as DriveCredentialRequest;
    expect(d.requestId, 'r1');
    expect(d.nodeId, 'web-01');
    expect(d.op, 'add');
    expect(d.host, 'github.com');
    expect(d.credential!['token'], 't');
  });

  test(
    'NodeDriveCredentialRequest (hub→node) carries the stamped principal',
    () {
      final m = NodeDriveCredentialRequest(
        requestId: 'r2',
        principal: 'alice',
        op: 'remove',
        host: 'gitlab.com',
      );
      final d =
          codec.decodeControl(codec.encodeControl(m)).message
              as NodeDriveCredentialRequest;
      expect(d.principal, 'alice');
      expect(d.op, 'remove');
      expect(d.host, 'gitlab.com');
      expect(d.credential, isNull);
    },
  );

  test('responses round-trip masked entries and error messages', () {
    final node =
        codec
                .decodeControl(
                  codec.encodeControl(
                    const NodeDriveCredentialResponse(
                      requestId: 'r3',
                      ok: true,
                      entries: [
                        DriveCredentialEntry(
                          host: 'github.com',
                          description: 'GitPat(username: x, token: ***)',
                        ),
                      ],
                    ),
                  ),
                )
                .message
            as NodeDriveCredentialResponse;
    expect(node.ok, isTrue);
    expect(node.entries.single.host, 'github.com');
    expect(node.entries.single.description, contains('***'));

    final client =
        codec
                .decodeControl(
                  codec.encodeControl(
                    const DriveCredentialResponse(
                      requestId: 'r4',
                      ok: false,
                      message: 'Not authorized',
                    ),
                  ),
                )
                .message
            as DriveCredentialResponse;
    expect(client.ok, isFalse);
    expect(client.message, 'Not authorized');
    expect(client.entries, isEmpty);
  });
}
