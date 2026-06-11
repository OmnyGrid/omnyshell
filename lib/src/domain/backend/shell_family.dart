/// The command-language family of a node's interactive shell.
///
/// The interactive `connect`/`resume` loop drives the remote shell with a
/// prompt-completion marker and a command wrapper whose *syntax* depends on the
/// shell: a POSIX shell (`/bin/sh`, `bash`, including Git Bash/WSL on Windows),
/// Windows PowerShell, or `cmd.exe`. The node reports which family it launched so
/// the client emits the matching dialect (see `ShellDialect`).
enum ShellFamily {
  /// A POSIX shell (`sh`, `bash`, `zsh`, Git Bash/WSL). Uses `trap`/`eval`/`stty`
  /// and a `printf`/`git`/`id` marker.
  posix,

  /// Windows PowerShell (`pwsh` or `powershell`).
  powershell,

  /// The Windows command prompt (`cmd.exe`). Degraded marker (no rich git/priv).
  cmd;

  /// The wire/JSON token for this family.
  String get wireName => name;

  /// Decodes a wire token, defaulting to [posix] for unknown/absent values so
  /// older peers (which never send the field) are treated as POSIX.
  static ShellFamily fromWire(String? value) => switch (value) {
    'powershell' => ShellFamily.powershell,
    'cmd' => ShellFamily.cmd,
    _ => ShellFamily.posix,
  };
}
