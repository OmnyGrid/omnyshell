@TestOn('vm')
library;

import 'package:omnydrive/omnydrive.dart'
    show
        ProgressEvent,
        ProgressPhase,
        ProgressItemKind,
        ProgressItemState,
        SyncDirection,
        SyncRef,
        SyncState;
import 'package:omnyshell/src/application/client/drive/drive_manager.dart'
    show SyncOutcome;
import 'package:omnyshell/src/application/client/drive/mount_store.dart'
    show MountRecord;
import 'package:omnyshell/src/shared/utils/progress_bar.dart';
import 'package:test/test.dart';

void main() {
  group('formatSyncProgress (per-path, in-session)', () {
    test('summarizes a completed upload with raw and wire sizes', () {
      final line = formatSyncProgress(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          total: 7,
          completed: 5,
          path: 'src/main.dart',
          itemKind: ProgressItemKind.transferred,
          itemState: ProgressItemState.completed,
          itemSize: 4096,
          itemTotalBytes: 1024,
        ),
      );
      expect(line, '↑ src/main.dart  (4.0 KB → 1.0 KB wire)');
    });

    test('marks a deduplicated (copied) path', () {
      final line = formatSyncProgress(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          total: 7,
          completed: 6,
          path: 'lib/dup.dart',
          itemKind: ProgressItemKind.copied,
          itemState: ProgressItemState.completed,
        ),
      );
      expect(line, '≡ lib/dup.dart  (deduped)');
    });

    test('marks a removed path', () {
      final line = formatSyncProgress(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          total: 7,
          completed: 7,
          path: 'old.txt',
          itemKind: ProgressItemKind.removed,
          itemState: ProgressItemState.completed,
        ),
      );
      expect(line, '- old.txt  (removed)');
    });

    test('suppresses in-flight started/progress events', () {
      expect(
        formatSyncProgress(
          const ProgressEvent(
            phase: ProgressPhase.transferring,
            path: 'a.txt',
            itemKind: ProgressItemKind.transferred,
            itemState: ProgressItemState.progress,
            itemBytes: 10,
            itemTotalBytes: 100,
          ),
        ),
        isNull,
      );
    });

    test('suppresses the bulk count event (per-path lines carry detail)', () {
      expect(
        formatSyncProgress(
          const ProgressEvent(
            phase: ProgressPhase.transferring,
            total: 3,
            completed: 1,
          ),
        ),
        isNull,
      );
    });

    test('renders a coarse git phase message', () {
      expect(
        formatSyncProgress(
          const ProgressEvent(
            phase: ProgressPhase.transferring,
            message: 'pushing',
          ),
        ),
        'pushing…',
      );
    });

    test('returns null for the terminal done phase', () {
      expect(
        formatSyncProgress(
          const ProgressEvent(
            phase: ProgressPhase.done,
            message: 'Synchronized',
          ),
        ),
        isNull,
      );
    });
  });

  group('SyncProgressBar (live multi-bar)', () {
    test('draws a bar per concurrent upload plus an overall line', () {
      final out = _CapturingSink();
      final bar = SyncProgressBar(out: out, enabled: true);
      // Two files in flight: started events are milestones, so each repaints.
      bar.update(_started('a.txt', 0, 100));
      bar.update(_started('b.bin', 0, 200));
      bar.update(_progress('a.txt', 50, 100));
      final text = out.buffer.toString();
      expect(text, contains('a.txt'));
      expect(text, contains('b.bin'));
      expect(text, contains('↑')); // transferred mark
      expect(text, contains('/2 files')); // overall line
      expect(text, contains('\x1b[')); // ANSI in-place redraw
    });

    test('drops an item from the view once it completes', () {
      final out = _CapturingSink();
      final bar = SyncProgressBar(out: out, enabled: true);
      bar.update(_started('a.txt', 0, 100));
      bar.update(_completed('a.txt', 1, 1));
      bar.finish();
      // After finish() the live block is cleared; nothing of a.txt should be
      // left "drawn" — the only writes are cursor/clear escapes.
      final text = out.buffer.toString();
      expect(text, contains('\x1b[2K')); // clear-line escapes used to wipe it
    });

    test('is a no-op when disabled (piped output stays clean)', () {
      final out = _CapturingSink();
      final bar = SyncProgressBar(out: out, enabled: false);
      bar.update(_started('a.txt', 0, 100));
      bar.update(_completed('a.txt', 1, 1));
      bar.finish();
      expect(out.buffer.toString(), isEmpty);
    });

    test('falls back to a single line for a coarse git phase', () {
      final out = _CapturingSink();
      final bar = SyncProgressBar(out: out, enabled: true);
      bar.update(
        const ProgressEvent(
          phase: ProgressPhase.transferring,
          message: 'pushing',
        ),
      );
      expect(out.buffer.toString(), contains('pushing…'));
    });
  });

  group('formatSyncReport', () {
    test('summarizes counts and raw vs on-wire bytes', () {
      final o = SyncOutcome(
        record: _record(),
        direction: SyncDirection.push,
        applied: 4,
        transferredPaths: const ['a.txt', 'b.txt', 'c.txt'],
        copiedPaths: const ['d.txt'],
        bytesTransferred: 4096,
        bytesOnWire: 1024,
      );
      expect(
        formatSyncReport(o),
        'Synced push: 3 transferred, 1 copied · 4.0 KB (1.0 KB on wire).',
      );
    });

    test('lists every path when verbose', () {
      final o = SyncOutcome(
        record: _record(),
        direction: SyncDirection.push,
        applied: 2,
        transferredPaths: const ['a.txt'],
        copiedPaths: const ['b.txt'],
        removedPaths: const ['c.txt'],
        bytesTransferred: 10,
        bytesOnWire: 10,
      );
      final report = formatSyncReport(o, verbose: true);
      expect(report, contains('1 transferred, 1 copied, 1 removed'));
      expect(report, contains('\n  + a.txt'));
      expect(report, contains('\n  = b.txt'));
      expect(report, contains('\n  - c.txt'));
      // Equal raw and wire sizes collapse to a single figure.
      expect(report, contains('· 10 B.'));
      expect(report, isNot(contains('on wire')));
    });

    test('reports a no-op sync', () {
      expect(formatSyncReport(_outcome()), 'Already up to date.');
    });

    test('falls back to the applied count for git (no per-path metrics)', () {
      final o = SyncOutcome(
        record: _record(),
        direction: SyncDirection.pull,
        applied: 3,
        publishedBranch: 'feature/x',
      );
      expect(
        formatSyncReport(o),
        'Synced pull: 3 change(s) (published feature/x).',
      );
    });
  });
}

ProgressEvent _started(String path, int bytes, int total) => ProgressEvent(
  phase: ProgressPhase.transferring,
  total: 2,
  completed: 0,
  path: path,
  itemKind: ProgressItemKind.transferred,
  itemState: ProgressItemState.started,
  itemBytes: bytes,
  itemTotalBytes: total,
  itemSize: total,
);

ProgressEvent _progress(String path, int bytes, int total) => ProgressEvent(
  phase: ProgressPhase.transferring,
  total: 2,
  completed: 0,
  path: path,
  itemKind: ProgressItemKind.transferred,
  itemState: ProgressItemState.progress,
  itemBytes: bytes,
  itemTotalBytes: total,
  itemSize: total,
);

ProgressEvent _completed(String path, int completed, int total) =>
    ProgressEvent(
      phase: ProgressPhase.transferring,
      total: total,
      completed: completed,
      path: path,
      itemKind: ProgressItemKind.transferred,
      itemState: ProgressItemState.completed,
    );

MountRecord _record() => MountRecord(
  id: 'm1',
  nodeId: 'n1',
  name: 'demo',
  kind: 'dir',
  remotePath: '/srv/demo',
  readWrite: true,
  driveId: 'd1',
  mountedAt: DateTime(2020),
  syncState: SyncState(baselineRef: SyncRef.directory('deadbeef')),
);

SyncOutcome _outcome() => SyncOutcome(record: _record());

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
