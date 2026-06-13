@TestOn('vm')
library;

import 'package:omnyshell/src/application/client/drive/workspace_layout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Unit coverage for the `run --with` wrapper computation: picking the common
/// ancestor to mount, deriving the include whitelist for the named members, and
/// the remote cwd sub-path (see [computeWorkspaceLayout]).
void main() {
  // Build absolute paths the same way on POSIX and Windows test hosts.
  String abs(List<String> segs) =>
      p.joinAll([p.rootPrefix(p.current), ...segs]);

  group('computeWorkspaceLayout', () {
    test('direct sibling: wrapper = parent, both subtrees included', () {
      final x = abs(['parent', 'x']);
      final dep = abs(['parent', 'dependency-project']);

      final layout = computeWorkspaceLayout(x, [dep]);

      expect(layout.wrapper, abs(['parent']));
      expect(layout.cwdSubPath, 'x');
      expect(layout.cwdIsRoot, isFalse);
      expect(layout.include, [
        '/x',
        '/x/**',
        '/dependency-project',
        '/dependency-project/**',
      ]);
    });

    test('deeper dependency hoists the wrapper but keeps relative paths', () {
      final x = abs(['root', 'apps', 'x']);
      final dep = abs(['root', 'libs', 'dep']);

      final layout = computeWorkspaceLayout(x, [dep]);

      expect(layout.wrapper, abs(['root']));
      expect(layout.cwdSubPath, 'apps/x');
      expect(layout.include, [
        '/apps/x',
        '/apps/x/**',
        '/libs/dep',
        '/libs/dep/**',
      ]);
    });

    test('a --with nested inside --dir yields a full mount (no filter)', () {
      final x = abs(['parent', 'x']);
      final nested = abs(['parent', 'x', 'sub']);

      final layout = computeWorkspaceLayout(x, [nested]);

      expect(layout.wrapper, x);
      expect(layout.cwdSubPath, '.');
      expect(layout.cwdIsRoot, isTrue);
      expect(layout.include, isEmpty);
    });

    test('multiple --with dirs are all whitelisted', () {
      final x = abs(['ws', 'x']);
      final a = abs(['ws', 'a']);
      final b = abs(['ws', 'b']);

      final layout = computeWorkspaceLayout(x, [a, b]);

      expect(layout.wrapper, abs(['ws']));
      expect(layout.include, ['/x', '/x/**', '/a', '/a/**', '/b', '/b/**']);
    });
  });
}
