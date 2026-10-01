import 'package:omnyshell/src/shared/utils/units.dart';
import 'package:test/test.dart';

void main() {
  group('parseByteSize', () {
    final cases = <String, int?>{
      '0': 0,
      '512': 512,
      '512b': 512,
      '1k': 1024,
      '1KB': 1024,
      '1KiB': 1024,
      '32M': 32 * mib,
      '32MiB': 32 * mib,
      ' 32 mb ': 32 * mib,
      '1.5M': (1.5 * mib).round(),
      '2G': 2 * 1024 * mib,
      '2GiB': 2 * 1024 * mib,
      '': null,
      'abc': null,
      '-1': null,
      '1T': null,
      '1.M': null,
    };
    cases.forEach((input, want) {
      test('"$input" → $want', () => expect(parseByteSize(input), want));
    });
  });

  group('formatByteSize', () {
    final cases = <int, String>{
      0: '0 B',
      512: '512 B',
      1024: '1 KiB',
      1536: '1.5 KiB',
      32 * mib: '32 MiB',
      (12.3 * mib).round(): '12.3 MiB',
      128 * mib: '128 MiB',
      3 * 1024 * mib: '3 GiB',
    };
    cases.forEach((input, want) {
      test('$input → $want', () => expect(formatByteSize(input), want));
    });
  });

  group('parseDurationArg', () {
    final cases = <String, Duration?>{
      '0': Duration.zero,
      '250ms': const Duration(milliseconds: 250),
      '30s': const Duration(seconds: 30),
      '5m': const Duration(minutes: 5),
      '2H': const Duration(hours: 2),
      '1d': const Duration(days: 1),
      '': null,
      '5': null,
      '5x': null,
      '-1s': null,
    };
    cases.forEach((input, want) {
      test('"$input" → $want', () => expect(parseDurationArg(input), want));
    });
  });

  group('formatDurationArg', () {
    final cases = <Duration, String>{
      Duration.zero: '0',
      const Duration(milliseconds: 1500): '1500ms',
      const Duration(seconds: 30): '30s',
      const Duration(seconds: 90): '90s',
      const Duration(minutes: 5): '5m',
      const Duration(hours: 2): '2h',
      const Duration(days: 3): '3d',
    };
    cases.forEach((input, want) {
      test('$input → $want', () => expect(formatDurationArg(input), want));
    });

    test('round-trips through parseDurationArg', () {
      for (final d in cases.keys) {
        expect(parseDurationArg(formatDurationArg(d)), d);
      }
    });
  });
}
