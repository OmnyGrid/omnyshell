@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:test/test.dart';

/// Compiles test/support/aot/render_frames.dart ahead-of-time and runs it.
///
/// Regression test for the 1.64.2 `:ide` crash: `ScreenBuffer.renderDiff`
/// promoted its nullable `previous` through a `reusable` boolean, and the AOT
/// compiler moved the `previous._cells` read ahead of that guard, so the very
/// first frame dereferenced `null` (`SIGSEGV`, `si_addr=0xf`). Shipped binaries
/// are AOT-compiled, but `dart test` runs under the JIT, where the code was
/// correct — only a real `dart compile exe` reproduces it.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('omnyshell-aot'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'renderDiff survives AOT compilation (first frame, diff, resize)',
    () async {
      final exe =
          '${tmp.path}/render_frames${Platform.isWindows ? '.exe' : ''}';
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'test/support/aot/render_frames.dart',
        '-o',
        exe,
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}${compiled.stderr}',
      );

      final run = await Process.run(exe, const []);
      expect(
        run.exitCode,
        0,
        reason: 'the AOT binary crashed:\n${run.stdout}${run.stderr}',
      );
      expect(run.stdout as String, startsWith('rendered '));
    },
  );
}
