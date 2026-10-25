// An entry point compiled ahead-of-time by
// test/integration/aot_render_test.dart. It drives [ScreenBuffer.renderDiff]
// the way `:ide` and the dashboard do (a first frame with no previous one,
// then diffs, then a resize) so AOT-only miscompilations surface as a crash.
// `dart test` runs under the JIT, which never reproduced them.
import 'package:omnyshell/src/application/client/ide/tui/screen_buffer.dart';
import 'package:omnyshell/src/application/client/ide/tui/style.dart';

void main(List<String> args) {
  // Sizes come from argv so the compiler cannot fold them to constants.
  final width = 80 + args.length;
  final height = 24 + args.length;
  var bytes = 0;
  ScreenBuffer? front;
  for (var i = 0; i < 20; i++) {
    // Resize halfway through: a size change must repaint everything.
    final w = i < 10 ? width : width + 20;
    final frame = ScreenBuffer(w, height)
      ..drawText(0, i % height, 'frame $i', const Style(bold: true));
    bytes += frame.renderDiff(front).length;
    front = frame;
  }
  print('rendered $bytes');
}
