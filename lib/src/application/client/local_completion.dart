import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/backend/shell_backend.dart';
import '../../domain/backend/shell_family.dart';
import '../../domain/backend/shell_request.dart';
import '../../domain/entities/session.dart';
import 'shell_dialect.dart';

/// The most candidates a single TAB completion will return, so a huge directory
/// cannot flood the terminal. Matches the remote completion cap.
const _maxCandidates = 200;

/// Generates TAB-completion candidates for [word] by running the [dialect]'s
/// completion command as a one-shot [SessionMode.exec] on a local [backend],
/// reading its stdout to EOF.
///
/// This is the local counterpart to the remote path, which issues the same
/// `dialect.completionCommand(...)` via `ClientRuntime.execute`. Running it in
/// [cwd] under [family]'s interpreter keeps relative-path completion correct.
/// Best-effort: callers treat a thrown error (including the [timeout]) as "no
/// candidates".
Future<List<String>> localCompletionCandidates(
  ShellBackend backend,
  ShellDialect dialect,
  String word, {
  required bool isCommand,
  required ShellFamily family,
  String? cwd,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final session = await backend.start(
    ShellRequest(
      mode: SessionMode.exec,
      command: dialect.completionCommand(word, isCommand: isCommand),
      cwd: cwd,
      shellFamily: family,
    ),
  );
  final out = BytesBuilder(copy: false);
  final outSub = session.stdout.listen(out.add);
  // Drain stderr so a chatty completion command never blocks on a full pipe.
  final errSub = session.stderr.listen((_) {});
  try {
    await session.exitCode.timeout(timeout);
  } finally {
    await outSub.cancel();
    await errSub.cancel();
  }
  final candidates = utf8
      .decode(out.takeBytes(), allowMalformed: true)
      .split('\n')
      .map((s) => s.trimRight())
      .where((s) => s.isNotEmpty)
      .toList();
  return candidates.length > _maxCandidates
      ? candidates.sublist(0, _maxCandidates)
      : candidates;
}
