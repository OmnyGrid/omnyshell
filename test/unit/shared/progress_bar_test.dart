@TestOn('vm')
library;

import 'package:omnydrive/omnydrive.dart' show ProgressEvent, ProgressPhase;
import 'package:omnyshell/src/shared/utils/progress_bar.dart';
import 'package:test/test.dart';

void main() {
  group('formatSyncProgress', () {
    test('renders per-file directory progress with path', () {
      final line = formatSyncProgress(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          total: 7,
          completed: 5,
          message: 'src/main.dart',
        ),
      );
      expect(line, 'syncing 5/7: src/main.dart');
    });

    test('omits the path when the event carries none', () {
      final line = formatSyncProgress(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          total: 3,
          completed: 1,
        ),
      );
      expect(line, 'syncing 1/3');
    });

    test('renders a coarse git phase message', () {
      final line = formatSyncProgress(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          message: 'pushing',
        ),
      );
      expect(line, 'pushing…');
    });

    test('returns null for the terminal done phase', () {
      final line = formatSyncProgress(
        const ProgressEvent(phase: ProgressPhase.done, message: 'Synchronized'),
      );
      expect(line, isNull);
    });

    test('returns null when there is nothing to transfer', () {
      final line = formatSyncProgress(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          total: 0,
          completed: 0,
        ),
      );
      expect(line, isNull);
    });
  });

  group('SyncProgressBar', () {
    test('draws a bar for the final file event, then finishes', () {
      final out = _CapturingSink();
      final bar = SyncProgressBar(out: out, enabled: true);
      // A "last" event (completed == total) bypasses the throttle and always
      // renders, so the test is independent of wall-clock timing.
      bar.update(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          total: 4,
          completed: 4,
          message: 'a.txt',
        ),
      );
      bar.finish();
      final text = out.buffer.toString();
      expect(text, contains('100%'));
      expect(text, contains('4/4 files'));
      expect(text, contains('a.txt'));
      expect(text, startsWith('\r')); // in-place redraw
      expect(text, endsWith('\n')); // finish() terminates the line
    });

    test('is a no-op when disabled (piped output stays clean)', () {
      final out = _CapturingSink();
      final bar = SyncProgressBar(out: out, enabled: false);
      bar.update(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          total: 2,
          completed: 2,
          message: 'a.txt',
        ),
      );
      bar.finish();
      expect(out.buffer.toString(), isEmpty);
    });
  });
}

/// Minimal [StringSink]-backed sink that records everything written via
/// [IOSink.write], which is all [SyncProgressBar] uses.
class _CapturingSink implements StringSink {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);
}
