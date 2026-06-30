import 'package:omnyshell/src/application/client/ide/tui/geometry.dart';
import 'package:test/test.dart';

void main() {
  group('Rect', () {
    test('edges and emptiness', () {
      const r = Rect(2, 3, 10, 4);
      expect(r.right, 12);
      expect(r.bottom, 7);
      expect(r.isEmpty, isFalse);
      expect(const Rect(0, 0, 0, 5).isEmpty, isTrue);
    });

    test('contains', () {
      const r = Rect(0, 0, 3, 3);
      expect(r.contains(2, 2), isTrue);
      expect(r.contains(3, 0), isFalse);
    });

    test('splitLeft clamps and partitions', () {
      const r = Rect(0, 0, 20, 5);
      final (left, right) = r.splitLeft(8);
      expect(left, const Rect(0, 0, 8, 5));
      expect(right, const Rect(8, 0, 12, 5));
      final (l2, r2) = r.splitLeft(100);
      expect(l2.width, 20);
      expect(r2.width, 0);
    });

    test('splitTop and splitBottom', () {
      const r = Rect(0, 0, 10, 8);
      final (top, bottom) = r.splitTop(3);
      expect(top, const Rect(0, 0, 10, 3));
      expect(bottom, const Rect(0, 3, 10, 5));
      final (rest, bar) = r.splitBottom(1);
      expect(rest, const Rect(0, 0, 10, 7));
      expect(bar, const Rect(0, 7, 10, 1));
    });

    test('deflate insets and clamps', () {
      const r = Rect(0, 0, 4, 4);
      expect(r.deflate(1, 1), const Rect(1, 1, 2, 2));
      expect(r.deflate(5, 5).isEmpty, isTrue);
    });
  });
}
