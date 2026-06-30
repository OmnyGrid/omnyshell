library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Guards that the web client barrel (`lib/omnyshell_client_web.dart`) and
/// everything it transitively imports/exports stays `dart:io`-free for a web
/// (dart2js / JS) target, so a web app can compile it.
///
/// Regression test for 1.43.1: `RemoteWorkspace` (exported by the barrel)
/// imported `local_workspace.dart` (a `dart:io` library) *unconditionally* just
/// to reach `WorkspaceException`, which made dart2js silently skip compiling any
/// entrypoint that imported the barrel.
///
/// Conditional imports (`import 'x_io.dart' if (dart.library.js_interop)
/// 'x_web.dart'`) are resolved to the branch dart2js would pick for the web, so
/// legitimately platform-split libraries (transport, tunnel) are not flagged.
void main() {
  test('omnyshell_client_web.dart transitively imports no dart:io on web', () {
    expect(
      Directory('lib').existsSync(),
      isTrue,
      reason: 'test must run from the package root',
    );

    final barrel = File('lib/omnyshell_client_web.dart');
    expect(barrel.existsSync(), isTrue, reason: 'web barrel not found');

    // Matches a whole import/export directive up to its terminating `;`.
    final directive = RegExp(r'^(?:import|export)\b[^;]*;', multiLine: true);
    final quoted = RegExp('''['"]([^'"]+)['"]''');
    final conditional = RegExp('''if\\s*\\(([^)]*)\\)\\s*['"]([^'"]+)['"]''');

    final offenders = <String>[];
    final visited = <String>{};

    // Whether `dart.library.X` is satisfied for a web/JS target.
    bool condTrueForWeb(String cond) {
      final neg = cond.trimLeft().startsWith('!');
      final webLib = RegExp(
        r'dart\.library\.(js|js_interop|js_util|html|wasm)',
      );
      final bool base;
      if (cond.contains('dart.library.io')) {
        base = false; // dart:io is unavailable on web
      } else if (webLib.hasMatch(cond)) {
        base = true;
      } else {
        base = false; // unknown condition → fall back to the default branch
      }
      return neg ? !base : base;
    }

    // The URI dart2js would resolve this directive to for a web target.
    String? webUriOf(String body) {
      final defaultUri = quoted.firstMatch(body)?.group(1);
      for (final m in conditional.allMatches(body)) {
        if (condTrueForWeb(m.group(1)!)) return m.group(2);
      }
      return defaultUri;
    }

    void walk(String absPath, List<String> chain) {
      final norm = p.normalize(absPath);
      if (!visited.add(norm)) return;

      final file = File(norm);
      if (!file.existsSync()) return; // generated/part-only — skip defensively

      final here = [...chain, p.relative(norm)];
      for (final d in directive.allMatches(file.readAsStringSync())) {
        final uri = webUriOf(d.group(0)!);
        if (uri == null) continue;

        if (uri == 'dart:io') {
          offenders.add('${here.join(' -> ')} -> dart:io');
          continue;
        }
        if (uri.startsWith('dart:')) continue;

        final String target;
        if (uri.startsWith('package:omnyshell/')) {
          target = p.join('lib', uri.substring('package:omnyshell/'.length));
        } else if (uri.startsWith('package:')) {
          continue; // third-party package — not part of our lib graph
        } else {
          target = p.join(p.dirname(norm), uri); // relative
        }
        walk(target, here);
      }
    }

    walk(barrel.path, const []);

    expect(
      offenders,
      isEmpty,
      reason:
          'the web barrel must stay dart:io-free so it compiles with dart2js; '
          'offending import chain(s):\n  ${offenders.join('\n  ')}',
    );
  });
}
