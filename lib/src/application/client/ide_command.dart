import 'dart:io';

import 'package:command_shield/command_shield.dart'
    show Analyzer, CommandShield, KnowledgeRiskDetector, SecurityAnalyzer;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../ai/ai_config_io.dart';
import '../ai/providers/provider_factory.dart';
import 'ide/ide_app.dart';
import 'local_command.dart';

/// Registers the `:ide` full-screen editor command on a [LocalCommandRegistry].
///
/// `:ide` needs a real terminal and local filesystem access (`dart:io`), so —
/// like the file-transfer commands — it is kept out of the browser-safe default
/// set and added explicitly by native embedders:
/// `LocalCommandRegistry.withDefaults()..addIdeCommand()`.
extension IdeCommands on LocalCommandRegistry {
  /// Adds the `:ide` command (alias `:edit`) to this registry.
  void addIdeCommand() => register(IdeCommand());
}

/// The `:ide [path]` local command: opens a full-screen, IntelliJ/VS Code-style
/// terminal IDE rooted at [path] (default: the current directory). It shows a
/// file-tree sidebar, tabs of open files, syntax highlighting per file type and
/// a git-change gutter, and lets you edit and save files — all without leaving
/// the omnyShell session. Press `Ctrl-Q` to return to the shell.
///
/// The IDE operates on the **local** filesystem (the synced OmnyDrive workspace
/// or this machine's project), so navigation and editing are instant with no
/// per-keystroke round-trips to the node.
class IdeCommand extends LocalCommand {
  @override
  String get name => 'ide';

  @override
  List<String> get aliases => const ['edit'];

  @override
  String get description => 'Open the full-screen TUI IDE (file tree + editor)';

  @override
  String? get usage =>
      ':ide [path]\n'
      '    Open a full-screen IDE rooted at [path] (default: current dir).\n'
      '    File-tree sidebar, file tabs, syntax highlighting and a git-change\n'
      '    gutter; edit and Ctrl-S to save. Ctrl-Q returns to the shell.\n'
      '    Keys: Ctrl-B focus tree/editor · Ctrl-N/P switch tabs ·\n'
      '          Ctrl-F find · Ctrl-L go to line · Ctrl-T terminal ·\n'
      '          Ctrl-A AI agent · Ctrl-W close tab · Enter open.';

  @override
  Future<void> run(LocalCommandContext context, List<String> args) async {
    final runFullScreen = context.runFullScreen;
    if (runFullScreen == null) {
      context.writeLine(':ide requires an interactive terminal.');
      return;
    }
    if (args.length > 1) {
      context.writeLine('usage: :ide [path]');
      return;
    }

    final root = _resolveRoot(args.isEmpty ? null : args.first);
    final dir = Directory(root);
    if (!dir.existsSync()) {
      context.writeLine(':ide: no such directory: $root');
      return;
    }

    // Wire the AI agent panel to the configured provider (env / ai.yaml). When
    // none is configured the panel shows setup help instead. The agent's
    // run_command tool is gated by the same command_shield used by `:ai`.
    final aiConfig = AiConfigIo.load();
    final aiProvider = aiConfig == null
        ? null
        : providerFor(aiConfig, http.Client());
    final shield = CommandShield(
      analyzer: Analyzer(
        securityAnalyzer: SecurityAnalyzer(
          detectors: [
            ...SecurityAnalyzer.defaultDetectors,
            KnowledgeRiskDetector(),
          ],
        ),
      ),
    );

    await runFullScreen((input) async {
      final app = IdeApp(
        rootPath: root,
        input: input,
        aiProvider: aiProvider,
        aiModel: aiConfig?.model,
        shield: shield,
      );
      await app.run();
    });
  }

  /// Resolves the IDE root from an optional [pathArg], expanding `~` and making
  /// it absolute against the current directory.
  String _resolveRoot(String? pathArg) {
    if (pathArg == null || pathArg.isEmpty || pathArg == '.') {
      return p.normalize(Directory.current.path);
    }
    var path = pathArg;
    if (path == '~' || path.startsWith('~/')) {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null) {
        path = path == '~' ? home : p.join(home, path.substring(2));
      }
    }
    return p.normalize(p.absolute(path));
  }
}
