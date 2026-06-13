/// Builds the remote shell command that produces TAB-completion candidates for
/// the `connect` client.
///
/// The interactive client edits the command line locally (the remote shell runs
/// non-interactively, with no readline), so it cannot rely on the remote shell's
/// own completion. Instead, on TAB it runs a one-off `exec` command on the node
/// (via `ClientRuntime.execute`, in the session's current directory) that prints
/// candidate completions for the word under the cursor, one per line.
///
/// The actual snippet is shell-family specific and lives on [ShellDialect]
/// (`completionCommand`), so it matches the interactive session's shell (POSIX
/// `sh`, PowerShell or `cmd.exe`). This free function preserves the original
/// POSIX entry point used by callers/tests that don't carry a dialect; it simply
/// delegates to [PosixShellDialect].
library;

import 'shell_dialect.dart';

/// Returns a POSIX `sh` command that prints completion candidates for [word],
/// one per line. When [isCommand] is true the word is in command position.
///
/// Equivalent to `const PosixShellDialect().completionCommand(...)`; for
/// non-POSIX nodes use the session's [ShellDialect] directly.
String remoteCompletionCommand(String word, {required bool isCommand}) =>
    const PosixShellDialect().completionCommand(word, isCommand: isCommand);
