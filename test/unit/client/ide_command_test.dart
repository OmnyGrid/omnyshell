import 'dart:io';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('resolveLocalIdeRoot', () {
    final cwd = p.normalize(Directory.current.path);

    test('no arg / "." / "" uses the current directory', () {
      expect(resolveLocalIdeRoot(null), cwd);
      expect(resolveLocalIdeRoot(''), cwd);
      expect(resolveLocalIdeRoot('.'), cwd);
    });

    test('a relative path is made absolute against the current directory', () {
      expect(resolveLocalIdeRoot('sub'), p.join(cwd, 'sub'));
      expect(resolveLocalIdeRoot(p.join('a', 'b')), p.join(cwd, 'a', 'b'));
    });

    test('an absolute path is kept, normalized', () {
      final abs = p.join(cwd, 'a', '..', 'b');
      expect(resolveLocalIdeRoot(abs), p.join(cwd, 'b'));
      expect(resolveLocalIdeRoot(p.join(cwd, 'x')), p.join(cwd, 'x'));
    });

    test('"~" and "~/…" expand to the home directory', () {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null) return; // No home in this environment; nothing to test.
      expect(resolveLocalIdeRoot('~'), p.normalize(p.absolute(home)));
      expect(
        resolveLocalIdeRoot('~/proj'),
        p.normalize(p.absolute(p.join(home, 'proj'))),
      );
    });
  });
}
