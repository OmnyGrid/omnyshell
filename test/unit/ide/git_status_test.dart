import 'package:omnyshell/src/application/client/ide/git/git_status.dart';
import 'package:test/test.dart';

void main() {
  group('parseStatusPorcelain', () {
    test('classifies modified, added, untracked and deleted', () {
      const out =
          ' M lib/a.dart\n'
          'A  lib/b.dart\n'
          '?? lib/c.dart\n'
          ' D lib/d.dart\n';
      final m = parseStatusPorcelain(out);
      expect(m['lib/a.dart'], GitFileStatus.modified);
      expect(m['lib/b.dart'], GitFileStatus.added);
      expect(m['lib/c.dart'], GitFileStatus.untracked);
      expect(m['lib/d.dart'], GitFileStatus.deleted);
    });

    test('renames map both old and new paths', () {
      final m = parseStatusPorcelain('R  old.dart -> new.dart\n');
      expect(m['old.dart'], GitFileStatus.renamed);
      expect(m['new.dart'], GitFileStatus.renamed);
    });

    test('merge conflicts are reported', () {
      final m = parseStatusPorcelain('UU lib/x.dart\n');
      expect(m['lib/x.dart'], GitFileStatus.conflicted);
    });

    test('ignored entries', () {
      final m = parseStatusPorcelain('!! build/\n');
      expect(m['build/'], GitFileStatus.ignored);
    });
  });

  group('parseUnifiedDiffGutter', () {
    test('pure additions are marked added', () {
      const diff = '@@ -0,0 +1,2 @@\n+line one\n+line two\n';
      final g = parseUnifiedDiffGutter(diff);
      expect(g.marks[1], GutterMark.added);
      expect(g.marks[2], GutterMark.added);
      expect(g.deletionsBefore, isEmpty);
    });

    test('replaced lines are marked modified', () {
      const diff = '@@ -3,2 +3,2 @@\n-old a\n-old b\n+new a\n+new b\n';
      final g = parseUnifiedDiffGutter(diff);
      expect(g.marks[3], GutterMark.modified);
      expect(g.marks[4], GutterMark.modified);
    });

    test('more additions than removals: extras are added', () {
      const diff = '@@ -3,1 +3,3 @@\n-old\n+new a\n+new b\n+new c\n';
      final g = parseUnifiedDiffGutter(diff);
      expect(g.marks[3], GutterMark.modified);
      expect(g.marks[4], GutterMark.added);
      expect(g.marks[5], GutterMark.added);
    });

    test('pure deletions record a deletion marker', () {
      const diff = '@@ -5,2 +4,0 @@\n-gone a\n-gone b\n';
      final g = parseUnifiedDiffGutter(diff);
      expect(g.marks, isEmpty);
      expect(g.deletionsBefore, isNotEmpty);
    });

    test('multiple hunks accumulate', () {
      const diff =
          '@@ -1,0 +1,1 @@\n+top\n'
          '@@ -10,1 +11,1 @@\n-x\n+y\n';
      final g = parseUnifiedDiffGutter(diff);
      expect(g.marks[1], GutterMark.added);
      expect(g.marks[11], GutterMark.modified);
    });
  });
}
