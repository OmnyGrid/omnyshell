import 'package:omnyshell/omnyshell_client_web.dart';
import 'package:test/test.dart';

void main() {
  group('CommandHistoryBuffer', () {
    test('add skips blanks and consecutive duplicates, reporting change', () {
      final b = CommandHistoryBuffer();
      expect(b.add('ls'), isTrue);
      expect(b.add('ls'), isFalse); // consecutive duplicate
      expect(b.add('   '), isFalse); // blank
      expect(b.add('pwd'), isTrue);
      expect(b.entries, ['ls', 'pwd']);
    });

    test('caps to maxEntries, dropping the oldest', () {
      final b = CommandHistoryBuffer(maxEntries: 2)
        ..add('a')
        ..add('b')
        ..add('c');
      expect(b.entries, ['b', 'c']);
    });

    test('constructor caps a seeded list to the newest entries', () {
      final b = CommandHistoryBuffer(entries: ['a', 'b', 'c'], maxEntries: 2);
      expect(b.entries, ['b', 'c']);
    });

    test('prepend splices migrated entries and collapses the boundary dup', () {
      final b = CommandHistoryBuffer(entries: ['x', 'y']);
      b.prepend(['w', 'x']); // old tail "x" meets new head "x"
      expect(b.entries, ['w', 'x', 'y']);
    });

    test('sanitizeKey maps unsafe characters to underscores', () {
      expect(CommandHistoryBuffer.sanitizeKey('a/b c'), 'a_b_c');
      expect(CommandHistoryBuffer.sanitizeKey('alice@web-01'), 'alice@web-01');
      expect(CommandHistoryBuffer.sanitizeKey(''), '_');
    });
  });

  group('HistoryCursor', () {
    test('up/down walk entries and restore the stashed draft', () {
      final cursor = HistoryCursor(
        CommandHistoryBuffer(entries: ['one', 'two', 'three']),
      );
      expect(cursor.up(line: 'dr', prefix: ''), 'three');
      expect(cursor.up(line: 'dr', prefix: ''), 'two');
      expect(cursor.down(), 'three');
      expect(cursor.down(), 'dr'); // restored in-progress line
      expect(cursor.down(), isNull); // already on the fresh line
    });

    test('prefix restricts which entries up visits', () {
      final cursor = HistoryCursor(
        CommandHistoryBuffer(entries: ['git status', 'ls', 'git log']),
      );
      expect(cursor.up(line: 'git', prefix: 'git'), 'git log');
      expect(cursor.up(line: 'git', prefix: 'git'), 'git status');
      expect(cursor.up(line: 'git', prefix: 'git'), isNull); // no older match
    });

    test('reset returns to the fresh-line state', () {
      final cursor = HistoryCursor(CommandHistoryBuffer(entries: ['a', 'b']));
      cursor.up(line: '', prefix: '');
      cursor.reset();
      // After reset, the first up again yields the newest entry.
      expect(cursor.up(line: '', prefix: ''), 'b');
    });
  });
}
