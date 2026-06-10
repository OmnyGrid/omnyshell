import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyshell/src/shared/utils/screen_replay_buffer.dart';
import 'package:test/test.dart';

const List<int> _enter = [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68];
const List<int> _leave = [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c];

void main() {
  group('ScreenReplayBuffer', () {
    test('non-alt replay returns the whole retained tail', () {
      final b = ScreenReplayBuffer();
      b.add(utf8.encode('hello world'));
      expect(b.inAltScreen, isFalse);
      expect(utf8.decode(b.replaySnapshot()), 'hello world');
    });

    test('alt replay starts at the last alt-screen enter', () {
      final b = ScreenReplayBuffer();
      b.add(utf8.encode('shell prompt\n'));
      b.add(_enter);
      b.add(utf8.encode('NANO-FRAME'));
      expect(b.inAltScreen, isTrue);

      final snap = b.replaySnapshot();
      expect(snap.sublist(0, 8), _enter, reason: 're-enters the alt screen');
      final text = utf8.decode(snap);
      expect(text, contains('NANO-FRAME'));
      expect(text, isNot(contains('shell prompt')));
    });

    test('leaving the alt screen falls back to the tail', () {
      final b = ScreenReplayBuffer();
      b.add(_enter);
      b.add(utf8.encode('frame'));
      b.add(_leave);
      b.add(utf8.encode('\nback at prompt'));
      expect(b.inAltScreen, isFalse);
      expect(utf8.decode(b.replaySnapshot()), contains('back at prompt'));
    });

    test('toggles split across chunks are detected', () {
      final b = ScreenReplayBuffer();
      b.add(_enter.sublist(0, 5));
      b.add(_enter.sublist(5));
      expect(b.inAltScreen, isTrue);
    });

    test('replaySnapshot is non-destructive', () {
      final b = ScreenReplayBuffer();
      b.add(utf8.encode('abc'));
      b.replaySnapshot();
      expect(utf8.decode(b.replaySnapshot()), 'abc');
    });

    test('an alt-enter trimmed by the cap falls back to the bounded tail', () {
      final b = ScreenReplayBuffer(capacity: 32);
      b.add(_enter);
      b.add(Uint8List(64)); // pushes the alt-enter out of the retained window
      expect(b.inAltScreen, isTrue, reason: 'state is still known');
      expect(b.replaySnapshot().length, lessThanOrEqualTo(32));
    });
  });
}
