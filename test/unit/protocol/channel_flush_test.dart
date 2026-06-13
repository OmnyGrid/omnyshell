@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:omnyshell/omnyshell.dart';
import 'package:test/test.dart';

void main() {
  group('Channel.sendStdin onFlushed', () {
    test('reports cumulative bytes paced by the send window', () {
      final ch = Channel(1, (_) {});
      final reports = <int>[];

      // A payload larger than one window cannot all go out at once: only the
      // bytes the initial credit covers reach the wire (4 × 64 KB = 256 KB).
      final total = Channel.defaultWindow + 50 * 1024;
      ch.sendStdin(Uint8List(total), onFlushed: reports.add);

      expect(reports, isNotEmpty);
      expect(reports.last, lessThan(total));
      expect(reports.last, lessThanOrEqualTo(Channel.defaultWindow));
      // Strictly increasing, one entry per flushed chunk.
      for (var i = 1; i < reports.length; i++) {
        expect(reports[i], greaterThan(reports[i - 1]));
      }

      // Granting the remaining credit lets the tail flush and the count reach
      // the full total.
      ch.grantCredit(total);
      expect(reports.last, total);
    });

    test('reports the full total in one shot when it fits the window', () {
      final ch = Channel(2, (_) {});
      final reports = <int>[];
      const total = 10 * 1024; // well under the 256 KB window
      ch.sendStdin(Uint8List(total), onFlushed: reports.add);
      expect(reports.last, total);
    });

    test('omits progress when no callback is supplied', () {
      // Just exercises the default path; absence of a callback must not throw.
      final ch = Channel(3, (_) {});
      expect(() => ch.sendStdin(Uint8List(1024)), returnsNormally);
    });
  });
}
