import 'package:omnyshell/src/application/node/node_drive_service.dart';
import 'package:test/test.dart';

void main() {
  group('NodeDriveService.resolveRoot', () {
    test('translates an MSYS mount root on Windows', () {
      expect(
        NodeDriveService.resolveRoot('/c/Users/foo/dir-x', isWindows: true),
        r'C:\Users\foo\dir-x',
      );
      expect(
        NodeDriveService.resolveRoot('/d/work', isWindows: true),
        r'D:\work',
      );
    });

    test('leaves the MSYS root verbatim on POSIX nodes', () {
      // Guards the regression: the Windows-only branch must not fire elsewhere.
      expect(
        NodeDriveService.resolveRoot('/c/Users/foo/dir-x', isWindows: false),
        '/c/Users/foo/dir-x',
      );
    });

    test('leaves an already-Windows path unchanged on Windows', () {
      expect(
        NodeDriveService.resolveRoot(r'C:\Users\foo', isWindows: true),
        r'C:\Users\foo',
      );
    });

    test('leaves a non-drive POSIX root unchanged on Windows', () {
      // Not a `/<drive>/…` path — nothing to translate.
      expect(
        NodeDriveService.resolveRoot('/home/foo', isWindows: true),
        '/home/foo',
      );
      expect(
        NodeDriveService.resolveRoot('/mnt/c/foo', isWindows: true),
        '/mnt/c/foo',
      );
    });

    test('defaults a null command to the current directory', () {
      expect(NodeDriveService.resolveRoot(null, isWindows: false), '.');
      expect(NodeDriveService.resolveRoot(null, isWindows: true), '.');
    });

    test('is idempotent — a translated root re-resolves to itself', () {
      // The original crash was a double assignment of `late final _root`;
      // resolveRoot now produces a single stable value safe to assign once.
      final once = NodeDriveService.resolveRoot(
        '/c/Users/foo',
        isWindows: true,
      );
      expect(NodeDriveService.resolveRoot(once, isWindows: true), once);
    });
  });
}
