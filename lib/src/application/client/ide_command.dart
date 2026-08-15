import 'dart:io';

import 'package:command_shield/command_shield.dart'
    show Analyzer, CommandShield, KnowledgeRiskDetector, SecurityAnalyzer;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../domain/backend/shell_family.dart';
import '../ai/ai_config_io.dart';
import '../ai/providers/provider_factory.dart';
import 'ide/ide_app.dart';
import 'ide/ide_command_support.dart';
import 'ide/tui/terminal.dart' show Terminal;
import 'ide/workspace/local_workspace.dart';
import 'ide/workspace/remote_workspace.dart';
import 'ide/workspace/workspace.dart';
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
/// When run from `omnyshell connect`, the IDE operates on the **remote node's**
/// filesystem at the remote working directory (file reads/writes, listing, git
/// and the terminal/agent all run on the node). From `omnyshell local` it
/// operates on this machine's filesystem. The engine itself is filesystem-
/// agnostic (see [Workspace]) and `dart:io`-free, so a web app can embed it too.
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
    final arg = args.isEmpty ? null : args.first;

    // Connected → the remote node at its working directory; local → this machine.
    final Workspace workspace;
    if (context.client != null) {
      final root = resolveRemoteIdeRoot(arg, context.currentRemoteCwd?.call());
      if (root == null) {
        context.writeLine(
          ':ide: remote working directory unknown yet — run a command first, '
          'or pass an absolute path.',
        );
        return;
      }
      workspace = RemoteWorkspace(
        client: context.requireClient,
        nodeId: context.node.id.value,
        rootPath: root,
        shellFamily: context.shellFamily,
      );
    } else {
      final root = resolveLocalIdeRoot(arg);
      if (!Directory(root).existsSync()) {
        context.writeLine(':ide: no such directory: $root');
        return;
      }
      workspace = LocalWorkspace(root);
    }

    await runFullScreen(
      (input) => runIdeApp(
        workspace: workspace,
        input: input,
        shellFamily: context.shellFamily,
      ),
    );
  }
}

/// Resolves the local IDE root from an optional [pathArg], expanding `~` and
/// making it absolute against the current directory.
String resolveLocalIdeRoot(String? pathArg) {
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

/// Builds and runs the full-screen [IdeApp] over [workspace], returning when the
/// user quits it.
///
/// Shared by the in-session `:ide` command and the standalone `omnyshell ide`
/// CLI command, so both get the same AI agent and command-gating wiring: the
/// panel is wired to the provider configured via the environment / `ai.yaml`
/// (when none is configured it shows setup help instead), and the agent's
/// `run_command` tool is gated by the same `command_shield` used by `:ai`.
///
/// [input] is the host's forwarded stdin, for embedders that already own the
/// single stdin subscription (the interactive shell's line editor). Leave it
/// null — as the standalone CLI command does — to let [Terminal] read `stdin`
/// itself. [shellFamily] selects the syntax the agent validates its commands
/// against.
Future<void> runIdeApp({
  required Workspace workspace,
  Stream<List<int>>? input,
  ShellFamily? shellFamily,
}) async {
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
  final app = IdeApp(
    workspace: workspace,
    terminal: Terminal(inputOverride: input),
    aiProvider: aiProvider,
    aiModel: aiConfig?.model,
    shield: shield,
    commandSyntax: ideCommandSyntaxFor(shellFamily),
  );
  await app.run();
}
