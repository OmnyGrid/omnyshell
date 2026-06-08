import 'dart:convert';

import 'package:omnyshell/omnyshell_client.dart';
import 'package:test/test.dart';

List<int> _b(String s) => utf8.encode(s);

void main() {
  group('ScreenModeDetector', () {
    test('enters the alternate screen on ESC[?1049h', () {
      final d = ScreenModeDetector();
      expect(d.inAltScreen, isFalse);
      final changed = d.feed(_b('hello\x1b[?1049hworld'));
      expect(changed, isTrue);
      expect(d.inAltScreen, isTrue);
    });

    test('leaves the alternate screen on ESC[?1049l', () {
      final d = ScreenModeDetector();
      d.feed(_b('\x1b[?1049h'));
      final changed = d.feed(_b('bye\x1b[?1049l'));
      expect(changed, isTrue);
      expect(d.inAltScreen, isFalse);
    });

    test('also recognises the legacy 1047 variant', () {
      final d = ScreenModeDetector();
      expect(d.feed(_b('\x1b[?1047h')), isTrue);
      expect(d.inAltScreen, isTrue);
      expect(d.feed(_b('\x1b[?1047l')), isTrue);
      expect(d.inAltScreen, isFalse);
    });

    test('detects a sequence split across two chunks', () {
      final d = ScreenModeDetector();
      // Split the enter sequence mid-way: "\x1b[?10" then "49h".
      expect(d.feed(_b('text\x1b[?10')), isFalse);
      expect(d.inAltScreen, isFalse);
      expect(d.feed(_b('49h')), isTrue);
      expect(d.inAltScreen, isTrue);
    });

    test('returns false when the state does not change', () {
      final d = ScreenModeDetector();
      expect(d.feed(_b('plain output, no sequences')), isFalse);
      expect(d.inAltScreen, isFalse);
      d.feed(_b('\x1b[?1049h'));
      // Already in the alternate screen; another enter is no net change.
      expect(d.feed(_b('\x1b[?1049h')), isFalse);
      expect(d.inAltScreen, isTrue);
    });

    test('does not false-positive on "1049" without the ESC[? prefix', () {
      final d = ScreenModeDetector();
      expect(d.feed(_b('the number 1049h appears in text')), isFalse);
      expect(d.inAltScreen, isFalse);
    });

    test('keeps the final state when enter and leave are in one chunk', () {
      final d = ScreenModeDetector();
      // Enter then leave within a single chunk: net state is "left".
      expect(d.feed(_b('\x1b[?1049hsome ui\x1b[?1049l')), isFalse);
      expect(d.inAltScreen, isFalse);
    });

    test('reset clears state and carried bytes', () {
      final d = ScreenModeDetector();
      d.feed(_b('\x1b[?1049h'));
      d.reset();
      expect(d.inAltScreen, isFalse);
      // A dangling partial prefix from before reset must not complete a match.
      d.feed(_b('text\x1b[?10'));
      d.reset();
      expect(d.feed(_b('49h')), isFalse);
      expect(d.inAltScreen, isFalse);
    });
  });
}
