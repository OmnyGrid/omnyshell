library;

import 'package:omnyshell/src/application/client/ide/tui/ansi_terminal_driver.dart';
import 'package:omnyshell/src/application/client/ide/tui/screen_buffer.dart';
import 'package:omnyshell/src/application/client/ide/tui/style.dart';
import 'package:test/test.dart';

/// A driver that records its ANSI output and lifecycle-hook order.
class _FakeDriver extends AnsiTerminalDriver {
  final StringBuffer out = StringBuffer();
  final List<String> hooks = [];

  @override
  void writeAnsi(String ansi) => out.write(ansi);

  @override
  void onEnter() => hooks.add('enter');

  @override
  void onLeave() => hooks.add('leave');

  @override
  ({int cols, int rows}) get size => (cols: 80, rows: 24);

  @override
  Stream<List<int>> get input => const Stream<List<int>>.empty();

  @override
  Stream<void> get resizeEvents => const Stream<void>.empty();
}

void main() {
  test('enter runs onEnter before the alternate-screen sequence', () {
    final d = _FakeDriver();
    d.enter();
    expect(d.hooks, ['enter']);
    final s = d.out.toString();
    expect(s, contains('\x1b[?1049h'));
    expect(s, contains('\x1b[2J'));
    expect(s, contains('\x1b[?25l'));
    // onEnter (raw-mode/flow-control setup) runs before any bytes are written,
    // so the alternate-screen sequence is the very first output.
    expect(s.startsWith('\x1b[?1049h'), isTrue);
  });

  test('leave restores the screen, then runs onLeave', () {
    final d = _FakeDriver();
    d.leave();
    expect(d.hooks, ['leave']);
    final s = d.out.toString();
    expect(s, contains('\x1b[?25h'));
    expect(s, contains('\x1b[?1049l'));
  });

  test('mouse reporting is opt-in and turned off again on leave', () {
    final plain = _FakeDriver()..enter();
    plain.leave();
    expect(plain.out.toString(), isNot(contains('?1000'))); // never touched

    final d = _FakeDriver()..enter(mouseWheel: true);
    expect(d.out.toString(), contains('\x1b[?1000h\x1b[?1006h'));
    d.out.clear();
    d.leave();
    // Off before the main screen returns, so no report reaches the shell.
    expect(d.out.toString(), startsWith('\x1b[?1006l\x1b[?1000l'));

    // A later plain enter/leave does not re-disable what is already off.
    d
      ..out.clear()
      ..enter()
      ..leave();
    expect(d.out.toString(), isNot(contains('?1000')));
  });

  test('re-entering without mouse turns an earlier mouse mode off', () {
    final d = _FakeDriver()..enter(mouseWheel: true);
    d.out.clear();
    d.enter(); // no leave() in between
    expect(d.out.toString(), contains('\x1b[?1006l\x1b[?1000l'));
  });

  test('present writes the frame diff and positions the cursor (1-based)', () {
    final d = _FakeDriver();
    final frame = ScreenBuffer(5, 1)..drawText(0, 0, 'hi', Style.none);
    d.present(frame, cursorX: 1, cursorY: 0);
    final s = d.out.toString();
    expect(s, contains('hi'));
    expect(s, contains('\x1b[1;2H')); // 0-based (1,0) → 1-based row 1, col 2
    expect(s, contains('\x1b[?25h'));
  });

  test(
    'present diffs against the previous frame; invalidate forces a repaint',
    () {
      final d = _FakeDriver();
      d.present(ScreenBuffer(5, 1)..drawText(0, 0, 'hi', Style.none));
      d.out.clear();

      // Identical frame → no cell output.
      d.present(ScreenBuffer(5, 1)..drawText(0, 0, 'hi', Style.none));
      expect(d.out.toString(), isNot(contains('hi')));

      // After invalidate, the same content repaints in full.
      d.invalidate();
      d.present(ScreenBuffer(5, 1)..drawText(0, 0, 'hi', Style.none));
      expect(d.out.toString(), contains('hi'));
    },
  );
}
