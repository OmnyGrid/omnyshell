## 1.21.0

### Added

- **`.omnyignore` default-ignore file (omnydrive 1.6.0).** A directory mounted
  with neither `--include` nor `--exclude` now consults a gitignore-style
  `.omnyignore` at its root and turns those patterns into the drive's default
  **exclude** set, baked into the mount so every subsequent sync skips the ignored
  sub-paths. Lines are trimmed; blank lines and `#` comments are skipped;
  `!`-negation is unsupported (ignored). `--ignore-file <name>` selects a different
  file name (defaults to `.omnyignore`); explicit `--include`/`--exclude` override
  the file entirely. Honored across every directory-mount entry point — `omnyshell
  drive mount`, the in-session `:drive mount`, and the ephemeral mounts of
  `omnyshell run` / `exec --mount` (the resolved filter is computed before the
  mount-reuse lookup, so reuse still matches). Git mounts reject `--ignore-file`,
  as they already do for `--include`/`--exclude`.

## 1.20.0

### Added

- **Live per-file sync progress (omnydrive 1.5.0).** Directory-drive sync now
  reports each concurrent upload as its bytes stream, so the CLI draws a live
  multi-bar transfer view — one bar per in-flight file, tagged transferred (`↑`)
  vs deduplicated/copied (`≡`) — over an overall `N/M files` line, and prints a
  final report of file counts and raw vs on-wire (compressed) bytes. Pass
  `-v`/`--verbose` to `omnyshell drive sync` to list every transferred / copied /
  removed path. The in-session `:drive sync` command prints a per-path line as
  each file settles, plus the same summary.
- True socket-paced upload progress over the drive channel: `Channel.sendStdin`
  gained an optional `onFlushed` callback that reports cumulative bytes as the
  credit window lets each chunk onto the wire; `DriveRpcClient.write` /
  `ChannelContentSource.writeBytes` thread it into omnydrive's new
  `ContentSource.writeBytes(onProgress:)`, so the bars fill at the real transfer
  pace rather than jumping on completion.
- `SyncOutcome` now surfaces the run's `transferredPaths`, `copiedPaths`,
  `removedPaths`, `bytesTransferred` and `bytesOnWire` from omnydrive's enriched
  `SyncMetrics`.

### Changed

- Bumped the `omnydrive` dependency to `^1.5.0`.

## 1.19.0

### Added

- **Directory-drive sync deduplicates identical content (omnydrive 1.4.0).** When a
  pushed file's content already exists on the node — in an existing file or in
  another file sent the same run — the bytes now cross the wire once and the node
  copies them into place rather than receiving the payload again. Duplicate build
  artifacts, vendored files and the like sync for the cost of a single transfer.
  omnyshell tunnels omnydrive's new `ContentSource.copy`/`supportsCopy` over the
  drive channel via a new `copy` op: `ChannelContentSource` issues it and
  `NodeDriveService` executes the verified in-place copy against its
  `LocalContentSource`, falling back to a byte transfer if the source drifted.

### Changed

- Bumped the `omnydrive` dependency to `^1.4.0`.

## 1.18.1

### Fixed

- **`exec`/`run` no longer stall or truncate on long output.** A command that
  produced more than the channel's 256 KiB send window would stop streaming
  partway through. Two causes: the client never replenished the node's send
  window as it consumed output (so the credit drained to zero and the stream
  stalled permanently), and on process exit the node closed the channel — which
  discards the credit-gated outbox — before that queued output had transmitted
  (truncating the tail). The client now grants window credit per consumed chunk
  in `ClientRuntime.executeStreaming`, and the node waits for the channel outbox
  to drain (bounded) before closing the session.

## 1.18.0

### Changed

- **`omnyshell exec` and `omnyshell run` stream output live.** Both commands
  previously buffered all remote stdout/stderr and printed it only after the
  command exited, so a long-running command (e.g. `exec web-01 "make build"`)
  showed nothing until completion. They now forward each output chunk to the
  terminal as it arrives. A new `ClientRuntime.executeStreaming(...)` delivers
  chunks via `onStdout`/`onStderr` callbacks and returns the exit code; the
  existing buffered `ClientRuntime.execute(...)` is unchanged and now builds on
  top of it.

## 1.17.0

### Added

- **Gzip compression for directory-drive sync (omnydrive 1.3.0).** Drive content
  now transfers gzip-compressed over the `DriveMessage` channel. omnyshell carries
  drive content over its own Hub-brokered channel rather than omnydrive's HTTP
  transport, so the HTTP layer's automatic gzip never applied here; this brings the
  same saving to the channel by reusing omnydrive's transport-agnostic
  `ContentCompression` policy (gzip level 4) at the wire edges. File reads, file
  writes and the JSON manifest are compressed; payloads below 1 KiB and already-
  compressed file types (jpeg, png, mp4, zip, pdf, …) are sent verbatim. Each
  message carries a `gz` header flag so the receiver inflates only what was
  compressed. Git drives are unaffected (they move data via the git CLI).

## 1.16.0

### Added

- **`omnyshell run --with <dir>` co-mounts sibling dependencies.** When a remote
  run needs a directory the project references by a relative path (e.g. a build
  that reads `../dependency-project`), the repeatable `--with` option mounts the
  **nearest common ancestor** of `--dir` and every `--with` — a *wrapper* — and
  sets the remote working directory to `wrapper/<--dir>`, so the same relative
  reference resolves on the node. Only the named directories are synced (an
  `--include` whitelist built from their wrapper-relative paths is applied
  automatically); the rest of the wrapper is never pushed or pulled. Mount reuse
  now also keys on the filter, so changing the `--with` set creates a fresh mount
  instead of reusing one with a stale whitelist. This is the safe alternative to
  `..` traversal: every synced path stays within the mounted wrapper root.

## 1.15.0

### Added

- **Partial directory mounts via `--include`/`--exclude` (omnydrive 1.2.0).**
  `omnyshell drive mount` and the inner `:drive mount` gain repeatable
  `--include`/`--exclude` options (gitignore-style globs: `*`, `**`, `?`,
  trailing-slash subtree matching) so a mount can sync only part of a local
  directory. Exclude wins over include; include acts as a whitelist. The filter
  is rejected when combined with `--git` (directory mounts only). It is persisted
  on the mount record and enforced node-side at the serving boundary: the node
  applies it to every manifest/read/write/delete, so excluded files are never
  hashed, pushed, pulled, or deleted, and baseline hashes stay consistent across
  both sides of a sync.

### Changed

- **Bumped omnydrive 1.1.4 → 1.2.0.** The upgrade is backward-compatible for
  existing mounts: the new `PathFilter` defaults to empty (whole-tree sync) and
  the `Drive`/`LocalContentSource`/`ManifestBuilder` filter parameters are
  optional, so unfiltered mounts behave exactly as before.

## 1.14.0

### Changed

- **Faster directory manifests (omnydrive 1.1.4).** Bumped omnydrive, whose
  `ManifestBuilder` now backs each build with a persisted stat-cache
  (`<root>/.omnydrive/manifest-cache.json`), reusing a file's recorded hash when
  its `(size, mtime)` are unchanged. An unchanged mount with thousands of files
  now costs one `stat()` per file instead of a full read + SHA-256. The produced
  `FileManifest` — and therefore the content-addressed `SyncRef` OmnyShell's
  drive sync compares — is byte-identical to a full rebuild, so no OmnyShell code
  change was required. The cache is advisory: a missing, stale, or unwritable
  cache silently falls back to a full rebuild. The `.omnydrive` directory is
  excluded from manifests, so it is never synced.

## 1.13.0

### Changed

- **Faster directory drive sync (omnydrive 1.1.3).** Bumped omnydrive, whose
  `DirectorySynchronizer` now transfers changed files concurrently (up to 8 in
  flight) instead of one at a time, hiding per-file round-trip latency. This is
  safe over OmnyShell's single drive channel: request frames are written
  atomically per message (`Channel._sendData`) and the node serializes effects
  in arrival order (`NodeDriveService`), with replies matched by correlation id.
  No OmnyShell code change was required.

### Added

- **`omnyshell run` reuses a matching mount across repeated calls.** Running the
  same local directory against the same node no longer mints a new ephemeral
  mount and re-pushes the whole tree each time. If a registered read-write
  directory mount matches, `run` (and `exec --mount`) reuses it and only syncs
  the changed files before running. Matching: an explicit `--mount-path` matches
  on node + local dir + remote path; an ephemeral run (no `--mount-path`)
  reuses a previous *ephemeral* mount for the same node + local dir (its recorded
  path is reused). The most recently mounted match wins. Pass `--fresh` to force
  a brand-new mount. Mount records now persist an `ephemeral` flag to support
  this.

## 1.12.1

### Fixed

- **`omnyshell run` (and `exec --mount`) failed on the default directory.**
  Mounting `.` / `./` threw `Invalid drive id "<node>/."`: the absolute form of
  `.` ends in `/.`, so the derived mount name became `.`. `DriveManager`
  now normalizes the local path before deriving the mount name and sync root.
- **`omnyshell run` ephemeral mount failed when the node's working directory was
  not writable** (`PathAccessException: Creation failed, path = '.omnyshell'`,
  errno 13). The default ephemeral mount path was relative, so the node resolved
  it against its process working directory (often a non-writable system dir).
  It is now rooted at the node user's home (`~/.omnyshell/run/...`); the node
  expands a leading `~` in both the drive mount root and the exec working
  directory, so the mount lands somewhere writable and the command still runs in
  the same place. A user-supplied `~/...` `--mount-path` / `--cwd` is expanded
  too.

## 1.12.0

### Added

- **`omnyshell run` — edit locally, run remotely, get results back.** A new
  top-level command that mounts a local directory onto the node (pushing the
  files up), runs a command **inside** it, then syncs whatever the command
  produced back down to local. It wraps the existing OmnyDrive mount machinery,
  so it rides the same authenticated `wss` session — no extra ports. By default
  the mount is left registered (re-run, `drive sync`, or `drive unmount` later);
  the remote path is ephemeral unless `--mount-path` is given, and the command's
  working directory defaults to the mount path. Flags: `--dir` (local directory,
  defaults to the current dir), `--mount-path`, `--mount-name`, `--initial-sync`,
  `--sync-interval` (periodic sync-back while running), `--cwd`, `--unmount` and
  `--clean-remote` (delete the node copy on teardown).
- **`omnyshell exec` gains a working directory and the same mount lifecycle.**
  `--cwd <dir>` sets the remote command's working directory. `--mount <local-dir>`
  (with the same `--mount-path` / `--sync-interval` / `--unmount` / `--clean-remote`
  options as `run`) mounts a directory, runs the command in it, and syncs the
  results back — `run` is the convenience form that mounts a directory by default.

## 1.11.1

### Fixed

- **Windows service ran a stale version after an upgrade.** A
  `dart pub global activate` install launches as `dart <snapshot>`, and Windows
  **locks that pub-cache snapshot while the service runs** — so `pub global
  activate <new version>` could not rewrite it, and uninstalling then
  reinstalling the service just re-pinned the same stale snapshot, so the latest
  omnyshell never took effect. `service install` now stages a private copy of
  the runtime under `%LOCALAPPDATA%\OmnyShell\bin` (or `%OMNYSHELL_HOME%\bin`)
  and points the Task Scheduler task there: upgrades can rewrite the pub-cache
  snapshot freely, and each (re)install refreshes the copy from the
  currently-installed version. The installer also stops a running task first so
  its lock is released before the copy is replaced, and `uninstall` cleans up the
  staged copy.

## 1.11.0

### Added

- **TCP tunnels / port forwarding.** Expose an internal TCP port — a connected
  node's, or your own machine's (`--local`) — on a public port of the Hub, so
  external clients reach an otherwise-unreachable service (a NAT'd node's
  database, a localhost dev server) through `hub-host:PUBLIC_PORT`. Forwarded
  bytes ride the existing authenticated, multiplexed `wss` connection — no extra
  listener on the node and no new credential. The Hub binds the public listener
  within an operator-configured range (`hub start --tunnel-port-range
  20000-20100`, **fail-closed** when unset) and authorizes each open with the
  same `RoleBasedAuthorizer`. Ownership is by principal, so a node-exposed tunnel
  outlives the requesting client and can be listed or closed from a later
  connection. Use `omnyshell tunnel open <node> <port>` (or `--local <port>`),
  `omnyshell tunnel list` / `close`, the in-session `:tunnel` command, or the
  Client SDK (`openTunnel` / `listTunnels` / `closeTunnel`). Built on
  [`tcp_tunnel`](https://pub.dev/packages/tcp_tunnel)'s `PortRange`.
- **`:tree` local command.** Prints a sized directory tree of a remote path from
  inside an interactive session.

## 1.10.2

### Added

- **`:info` now reports the shell protocol family and more.** The listing adds the
  remote shell's command-language family (`POSIX (sh/bash)`, `PowerShell`, or
  `cmd.exe`) — useful on Windows nodes where the node picks the shell — alongside
  the node display name, global UID, connected Hub URI, operator labels, and the
  session id/mode.

### Fixed

- **Windows node service no longer leaves a black console window open.** A
  user-scope `service install` registered the Task Scheduler task with an
  interactive logon token, so the `cmd.exe` action's console window stayed
  visible on the desktop for as long as the node ran. User-scope tasks now use an
  **S4U** principal ("run whether the user is logged on or not"), so the daemon
  runs in a non-interactive session: no window appears, and it keeps running
  after logoff. System-scope installs (session 0) are unaffected.

- **`:tree` no longer crashes with a `FormatException` against a non-UTF-8 node.**
  The command decoded the remote `find`/`stat` output (and error text) with a
  strict UTF-8 decoder, so a Windows node's OEM-codepage error message threw
  `FormatException: Missing extension byte` and took down the session. Remote
  command output in the local commands is now decoded tolerantly
  (`allowMalformed: true`), matching the rest of the client. (Note: `:tree` still
  relies on POSIX `find`/`stat`, so it only produces a tree on nodes that provide
  them; on a bare Windows shell it now reports the error cleanly instead of
  crashing.)

## 1.10.1

### Fixed

- **Windows `connect` no longer fails when WSL is present but has no distro.** The
  shell probe picked `C:\Windows\System32\bash.exe` (the WSL launcher) because it
  exists on `%PATH%`; with no distro installed it prints "no distributions
  installed" and exits 1, closing the session immediately. Each `bash` candidate
  is now verified by running `bash -c "exit 0"` and is only chosen when it exits
  cleanly — an unusable WSL `bash.exe` is skipped and the probe falls through to
  PowerShell. A working WSL bash still wins; the check runs at most once per node
  process.

## 1.10.0

### Added

- **`connect` now works against Windows nodes.** The interactive session protocol
  was POSIX-only (`trap`, `eval`, `stty`, and a `printf`/`git`/`id` prompt
  marker), so connecting to a Windows node — which spawned `cmd.exe` — produced
  only "command not recognized" errors. The node now selects the best interactive
  shell on Windows, preferring **bash** (Git Bash / WSL), then **PowerShell**
  (`pwsh`/`powershell`), then **`cmd.exe`**, and reports the chosen shell *family*
  to the client (via `SessionOpened`). The client speaks a matching `ShellDialect`
  for that family:
  - **bash** reuses the proven POSIX protocol unchanged;
  - **PowerShell** emits a PowerShell-native prompt marker (cwd, git branch/status
    counts, and an `Administrator` → `root` privilege flag) with the per-line
    prompt suppressed;
  - **`cmd.exe`** is a degraded last resort that tracks the working directory
    (`%CD%`) only.

  POSIX nodes (Linux/macOS) and Windows-with-bash are byte-identical to before;
  Windows `exec` mode still runs through `cmd.exe /c` unchanged.

## 1.9.1

### Added

- **`omnyshell --version` (`-V`).** Prints `omnyshell <version>` and exits,
  following the usual console convention. The program name and version now also
  head the CLI `--help` output and the interactive `:help` listing.

### Fixed

- **Windows `service install` no longer fails with "cannot switch encoding".**
  The Task Scheduler definition that `schtasks /Create /XML` imports must be a
  UTF-16 file; it was written as UTF-8, so `schtasks` rejected it ("the XML is
  malformed … cannot switch encoding"). The file is now declared and written as
  UTF-16 (little-endian with a BOM).

## 1.9.0

### Added

- **`:tree` local command — a sized directory tree of a remote path.** Prints a
  `tree -lh`-style listing of a path on the connected node (default: the current
  remote directory), annotating every file with its size and every directory
  with its aggregated total in human-readable form. Supports `:tree [path]`,
  `-L <depth>` to limit display depth (`0` = unlimited), and `-a` to include
  hidden entries (dot-files are skipped by default). Symlinks are shown as
  non-followed leaves. The tree is built client-side from a single
  `find … -exec stat …` run on the node (GNU or BSD `stat` chosen by node OS),
  so directory totals stay accurate even when the display depth is truncated.

### Fixed

- **Installing the Node/Hub as a Windows service no longer fails with error
  1053.** `sc start dart_omnyshell_node` failed with "The service did not respond
  to the start or control request in a timely fashion" because a plain Dart
  console app cannot perform the in-process Service Control Manager handshake
  (`StartServiceCtrlDispatcher` → `SetServiceStatus`), so the SCM killed it after
  its timeout. On Windows the `service` commands now run the daemon through
  **Task Scheduler** (`schtasks.exe`) instead of the SCM: a boot-triggered task
  (system scope, runs as LocalSystem) or logon-triggered task (user scope) with
  no execution time limit and restart-on-failure, wrapping the run in `cmd.exe`
  to set `OMNYSHELL_HOME` and capture a log. Linux (systemd) and macOS (launchd)
  are unchanged.

## 1.8.3

### Fixed

- **`sessions list` now shows the real COMMAND and PATH.** The COMMAND column
  was always `-` and PATH was frozen at the directory each session was opened in
  (it never followed `cd`), for both attached and detached sessions. The default
  PTY backend runs the interactive shell *under* a `script(1)` wrapper, so the
  session pid is the wrapper's — whose controlling terminal is the node's, not
  the session's pty, and whose cwd never changes. Process inspection now descends
  to the real shell beneath the wrapper before reading its foreground command and
  working directory.

## 1.8.2

### Fixed

- **Detach no longer leaves stray escape sequences on the local terminal.** A
  local `:detach` returned early without restoring the terminal, so DEC private
  modes a full-screen remote program (vim, claude…) had enabled — mouse
  tracking, bracketed paste, alt-screen, hidden cursor, SGR — stayed on and the
  terminal kept emitting special characters (e.g. `ESC[<…M` mouse reports on
  every mouse move). Both detach paths now share one reset sequence and clean up
  the terminal.

## 1.8.1

### Changed

- **Upgraded `omnydrive` to `^1.1.2`.** Picks up the fix that prevents a mount
  sync from silently discarding local-only changes. OmnyShell already guards
  this in `DriveManager._autoDirection` (read-only mounts only push, read-write
  mounts only pull when the local copy is unchanged, and a two-sided change
  surfaces a conflict); added regression tests covering remote→local pulls of
  new node files, read-only mounts never pulling, and divergent syncs refusing
  to clobber local work.

## 1.8.0

### Added

- **Peek at a session's current screen without attaching.** The new
  `omnyshell sessions peek <node> <session-id>` prints a session's current
  screen — the same bytes a resume would paint, captured by the node's
  alt-screen-aware replay buffer — without connecting to it or delivering any
  input. Works for both running (attached) and detached sessions you own.
- **`sessions list` now shows the current command and path.** Each row gains a
  `COMMAND` (the foreground command, or `-` at the prompt) and `PATH` (the
  session's working directory) column, queried best-effort by the node from the
  OS (Linux/macOS).
- **New sessions start in your home directory.** A freshly opened session now
  starts in the node user's home directory (like `cd ~`) instead of wherever the
  node process was launched. An explicit per-request working directory still
  takes precedence.

### Changed

- **Profile `PATH` is deduplicated on export.** When syncing the node profile,
  the captured `PATH` now has empty and duplicate entries removed (first
  occurrence wins, order preserved) before it is written to `profile.yaml`.
- **Clearer `omnyshell node profile sync` reporting.** When nothing changes it
  reports `Node PATH already up to date.`; when it writes a change it now also
  reminds you to restart the node for the new `PATH` to take effect. (The
  restart hint is omitted during `node start`, which re-loads the profile
  immediately.)

## 1.7.0

### Added

- **Node environment profile (`~/.omnyshell/profile.yaml`).** Sessions run the
  node's shell non-interactively, so no rc file is sourced and `$PATH` starts
  bare. The node now applies an `env:` map from `~/.omnyshell/profile.yaml`
  (values support `${VAR}` expansion) as the `baseEnvironment` of every shell
  **and** exec session. On an interactive `node start` the node derives `PATH`
  from your login shell rc (`~/.zshrc`, `~/.bash_profile`, …) and prompts before
  writing it when it differs; non-interactive starts leave the profile untouched
  and print a hint. New flags `--profile <path>` and `--no-profile-sync`, plus an
  `omnyshell node profile sync [--yes]` subcommand to refresh on demand.
- **Remember `--insecure-skip-verify` at login.** Logging in with
  `--insecure-skip-verify` now asks whether to persist the setting for that Hub;
  when stored, later commands reusing the saved session skip TLS verification
  without re-passing the flag. A non-interactive login defaults to not storing
  it, and re-running `login` without the flag (or `logout`) clears it.

## 1.6.1

- Dependency updates in `pubspec.yaml`:
  - `cryptography`: updated from ^2.7.0 to ^2.9.0
  - `omnydrive`: updated from ^1.1.0 to ^1.1.1
  - `lints`: updated from ^6.0.0 to ^6.1.0
  - `test`: updated from ^1.25.6 to ^1.31.1

## 1.6.0

### Added

- **Manage OmnyDrive mounts from inside a session with `:drive`.** The new local
  command is the in-session counterpart of the top-level `omnyshell drive` CLI:
  because the session is already attached to one node, the node is implicit, so
  paths take no `<node>:` prefix and every operation is scoped to the connected
  node. Subcommands mirror the CLI — `:drive ls`, `:drive mount <local-dir>
  <remote-path>` (or `--git <url> <remote-path>`, with `--rw`,
  `--no-initial-sync`, `--name`, `--branch`, `--depth`), `:drive status`,
  `:drive sync [--push|--pull]`, `:drive resolve [--accept-local|--accept-origin|
  --reclone]`, `:drive remount`, and `:drive unmount [--sync-first]
  [--no-keep-remote]`. A mount-id belonging to a different node is refused, and
  mounts share the same on-disk registry as the CLI.
- **Background `:drive watch`.** `:drive watch <mount-id> [--interval S]
  [--debounce MS]` auto-syncs a mount in the background while the shell stays
  usable, logging each sync above the prompt; `:drive unwatch [<mount-id>]` stops
  one or all watchers (teardown also runs automatically when the session ends or
  the mount is unmounted). Background output repaints around the input line via a
  new `LocalCommandContext.printAbove` hook.
- **Live drive sync progress.** Every drive operation now reports progress as it
  runs instead of only a final count: `sync`, `mount`, `resolve`, `remount` and
  `watch`, for both the `omnyshell drive` CLI and the in-session `:drive` command.
  The top-level CLI renders an in-place bar
  (`[##########----] 71%  5/7 files  src/main.dart`); in-session prints a
  throttled `syncing N/M: path` line above the prompt. Per-file granularity for
  directory mounts comes from omnydrive ≥ 1.1.0's per-file `ProgressEvent`s; git
  push/clone show a coarse `pushing…` / `cloning…` phase. Threaded through a new
  `DriveManager` `onProgress` callback and a `SyncProgressBar` renderer.

## 1.5.1

### Fixed

- **No more stray characters on the terminal after a session detaches.** Two
  separate leaks were writing to the local terminal once a session was already
  gone. (1) The `connect` client never cancelled its remote stdout/stderr
  listeners on detach, so bytes still buffered in the channel were flushed
  afterwards — at an idle prompt the line editor repainted around them, smearing
  erase/prompt escape sequences onto the detached terminal. The listeners are now
  guarded against the detached state and cancelled on teardown. (2) When a session
  was detached from another window mid full-screen program, the terminal reset
  undid the alternate screen, cursor and color attributes but **not** mouse
  reporting, so every later mouse move spewed SGR mouse reports (`ESC[<…M`) onto
  the terminal. The detach reset now also disables every mouse-tracking mode
  (1000/1002/1003 and the 1005/1006/1015 encodings) and bracketed paste (2004).

- **Interactive sessions no longer freeze on heavy output.** The `connect`
  client consumed remote stdout/stderr without ever replenishing the channel's
  send window, so after a cumulative 256 KiB the node's flow-control credit
  drained and all further output stalled — the session appeared frozen. This
  surfaced most often with full-screen TUIs that repaint the whole screen on
  every scroll (e.g. `claude`'s plan view, `vim`, `less`, `htop`), which exhaust
  the window within a handful of redraws. The client now grants window credit for
  every chunk it consumes. The node grants stdin credit symmetrically, so a large
  paste into a full-screen program can't stall input either.

## 1.5.0

### Added

- **Detachable sessions.** Leave a node without killing the remote shell and
  reconnect later. From the interactive prompt, `:detach [timeout]` parks the
  session — the PTY, shell and child processes keep running on the node — and
  prints a short id to resume with (`:detach`, `:detach 30m`, `:detach 2h`,
  `:detach 1d`; units `s`/`m`/`h`/`d`). Manage detached sessions from the CLI:
  `omnyshell sessions list <node>`, `omnyshell sessions resume <node> <id>` (a
  full id, short handle or unambiguous prefix), and
  `omnyshell sessions kill <node> <id>`. Sessions are owned by one
  authenticated user on one node; the node enforces ownership and never reveals
  another user's sessions. A dropped client connection **auto-detaches** by
  default (preserving the shell) rather than terminating it. Output produced
  while detached is retained in an in-memory capture and replayed on resume.
  Detached-session state lives only in node memory — nothing is written to disk
  and it is lost on node restart by design. The Hub only authenticates, routes
  and correlates replies; it never persists detached-session metadata. New
  client APIs: `RemoteSession.detach()`, `ClientRuntime.resumeSession()`,
  `listDetachedSessions()`, `killDetachedSession()`; new `NodeConfig`
  `autoDetachOnDisconnect`, `autoDetachTimeout`, `cleanupInterval`.

- **Detach a running session from another window.** Because `:detach` can't be
  typed while a full-screen program (vim, top, less, a REPL) owns the terminal,
  `omnyshell sessions detach <node> [session-id] [timeout]` detaches a *running*
  session from a separate terminal — the attached window drops out of the
  full-screen app with its terminal restored and prints a resume hint, and the
  remote shell keeps running. With no `session-id` it targets your sole active
  session on that node (errors if several). `omnyshell sessions list <node>` now
  shows **active** sessions too (STATUS `attached`/`detached`) so you can find
  the id. New client APIs: `ClientRuntime.detachActiveSession()`,
  `listSessions()`, and `RemoteSession.wasDetached` / `detachOutcome`.

- **`sessions kill` terminates running sessions too.** `omnyshell sessions kill
  <node> <id>` now resolves both **active** (attached) and detached sessions, so
  you can kill a running session from another window; the attached client is
  disconnected. New `ClientRuntime.killSession()` (the old `killDetachedSession`
  remains as a deprecated alias).

- **Resume restores full-screen programs.** The node now keeps a continuous,
  alt-screen-aware capture of recent output for every session (not just while
  detached), so resuming into `nano`/`vim`/`htop`/`less` repaints the program's
  current screen — the frame it had drawn *before* detaching — instead of a
  blank terminal. Resume into a full-screen program attaches in passthrough
  without injecting a prompt marker (which previously typed into the program);
  the program's existing completion marker restores the prompt when it exits.
  Restoration is at the detached geometry. `SessionOpened` gains an `altScreen`
  flag (exposed as `RemoteSession.resumedInAltScreen`). The prompt-completion
  marker token is derived from the stable session id (reported unchanged across
  connect and resume), so a resumed client recognizes the marker the running
  program leaves behind and reliably repaints the prompt after the program
  exits — with the correct working directory.

## 1.4.0

### Added

- **Detachable sessions.** Leave a node without killing the remote shell and
  reconnect later. From the interactive prompt, `:detach [timeout]` parks the
  session — the PTY, shell and child processes keep running on the node — and
  prints a short id to resume with (`:detach`, `:detach 30m`, `:detach 2h`,
  `:detach 1d`; units `s`/`m`/`h`/`d`). Manage detached sessions from the CLI:
  `omnyshell sessions list <node>`, `omnyshell sessions resume <node> <id>` (a
  full id, short handle or unambiguous prefix), and
  `omnyshell sessions kill <node> <id>`. Sessions are owned by one
  authenticated user on one node; the node enforces ownership and never reveals
  another user's sessions. A dropped client connection **auto-detaches** by
  default (preserving the shell) rather than terminating it. Output produced
  while detached is retained in an in-memory capture and replayed on resume.
  Detached-session state lives only in node memory — nothing is written to disk
  and it is lost on node restart by design. The Hub only authenticates, routes
  and correlates replies; it never persists detached-session metadata. New
  client APIs: `RemoteSession.detach()`, `ClientRuntime.resumeSession()`,
  `listDetachedSessions()`, `killDetachedSession()`; new `NodeConfig`
  `autoDetachOnDisconnect`, `autoDetachTimeout`, `cleanupInterval`.

- **Detach a running session from another window.** Because `:detach` can't be
  typed while a full-screen program (vim, top, less, a REPL) owns the terminal,
  `omnyshell sessions detach <node> [session-id] [timeout]` detaches a *running*
  session from a separate terminal — the attached window drops out of the
  full-screen app with its terminal restored and prints a resume hint, and the
  remote shell keeps running. With no `session-id` it targets your sole active
  session on that node (errors if several). `omnyshell sessions list <node>` now
  shows **active** sessions too (STATUS `attached`/`detached`) so you can find
  the id. New client APIs: `ClientRuntime.detachActiveSession()`,
  `listSessions()`, and `RemoteSession.wasDetached` / `detachOutcome`.

- **`sessions kill` terminates running sessions too.** `omnyshell sessions kill
  <node> <id>` now resolves both **active** (attached) and detached sessions, so
  you can kill a running session from another window; the attached client is
  disconnected. New `ClientRuntime.killSession()` (the old `killDetachedSession`
  remains as a deprecated alias).

- **Resume restores full-screen programs.** The node now keeps a continuous,
  alt-screen-aware capture of recent output for every session (not just while
  detached), so resuming into `nano`/`vim`/`htop`/`less` repaints the program's
  current screen — the frame it had drawn *before* detaching — instead of a
  blank terminal. Resume into a full-screen program attaches in passthrough
  without injecting a prompt marker (which previously typed into the program);
  the program's existing completion marker restores the prompt when it exits.
  Restoration is at the detached geometry. `SessionOpened` gains an `altScreen`
  flag (exposed as `RemoteSession.resumedInAltScreen`). The prompt-completion
  marker token is derived from the stable session id (reported unchanged across
  connect and resume), so a resumed client recognizes the marker the running
  program leaves behind and reliably repaints the prompt after the program
  exits — with the correct working directory.

### Changed

- **Interactive `connect` now hands the terminal to the remote while a command
  runs, instead of guessing from the command text.** The managed prompt is drawn
  only when the shell is idle; the moment a command is dispatched the client
  enters raw passthrough and lets the remote program own the terminal until the
  `CwdMarker` completion signal returns. This fixes full-screen programs (vim,
  nano, less, top) and interactive line-readers (`read`, `y/N` confirmations,
  REPLs) corrupting — or being corrupted by — the local prompt, and replaces the
  fragile alternate-screen detection plus hardcoded foreground-program list.

- **Cooked-mode input now echoes correctly.** Because the remote shell runs with
  `stty -echo`, the dispatched command is wrapped to re-enable echo just for the
  program's runtime input (`stty echo ; eval '<cmd>' ; <marker> ; stty -echo`),
  so `read`/`cat`/`y-N` prompts show what you type while password prompts stay
  hidden (those programs disable echo themselves). No node-side change is needed.

### Fixed

- **Output arriving at the idle prompt no longer tangles with the input line.**
  A backgrounded job (`cmd &`) printing while you type now erases and repaints
  the prompt around its output.

## 1.3.3

- dart_service_manager: ^1.2.2

## 1.3.2

### Added

- **`--verbose` (`-v`) flag on every `omnyshell service` subcommand.** Drops the
  service manager's console logger to debug level so the underlying
  install/lifecycle steps (and the 1.2.0 user-systemd/privilege diagnostics)
  are printed; without it, info and warnings are shown as before.

- dart_service_manager: ^1.2.1

## 1.3.1

### Changed

- **Bumped `dart_service_manager` to `^1.2.0`.** `omnyshell service install`
  now benefits from the package's new install-time safeguards with no flag
  changes: on Linux, user-scoped installs auto-configure a persistent per-user
  systemd environment (enables lingering, resolves the user D-Bus bus and
  `XDG_RUNTIME_DIR`) so a `--user` Hub/Node survives logout/reboot and no longer
  hits `Failed to connect to bus`; and `install` now warns when the requested
  scope mismatches the current privilege level (e.g. running under sudo with the
  default user scope, or `--system` without elevation).

## 1.3.0

### Added

- **`omnyshell service` — install the Hub or Node as a native OS service.** A new
  command group registers the running `omnyshell` executable with the platform
  service manager (systemd on Linux, launchd on macOS, the Service Control Manager
  on Windows) via [`dart_service_manager`](https://pub.dev/packages/dart_service_manager),
  so a Hub or Node starts at boot and is restarted on failure. The flags passed to
  `service install <hub|node> …` are the exact `hub start` / `node start` flags and
  are captured into the generated unit/plist; path flags (`--cert`, `--key`,
  `--ca`, `--authorized-keys`) are absolutized. Subcommands: `install`,
  `uninstall`, `start`, `stop`, `restart`, `status`, and `reconfigure`. Installs to
  the current user by default; `--system` installs machine-wide and runs with
  `OMNYSHELL_HOME=/var/lib/omnyshell` (override with `--data-dir`). `--dry-run`
  prints the rendered definition without touching the system, and `--force`
  replaces an existing service.

## 1.2.2

### Fixed

- **Nodes now report their real OmnyShell version.** `NodeConfig.agentVersion`
  defaults to `omnyShellVersion` instead of a hardcoded `0.1.0`, so a node's
  advertised `Agent:` version (shown in `:info` and node details) reflects the
  actual build. `omnyShellVersion` is now the single source of truth and is kept
  in sync with `pubspec.yaml`, guarded by a new `version`-tagged test.

## 1.2.1

### Added

- **`--insecure-skip-verify` flag to bypass TLS verification.** Available on all
  connection commands (`login`, `node start`, `connect`, `exec`, `drive`, …), it
  disables both CA-trust and hostname verification so clients/nodes can reach a
  Hub presenting a self-signed certificate or a cert whose CN/SAN does not match
  the connection hostname (common with self-hosted hubs). Opt-in and insecure:
  it prints a `[security] WARNING` to stderr whenever active and is intended only
  for trusted self-signed/dev hubs. The setting is per-invocation and is not
  persisted into saved sessions.

## 1.2.0

### Added

- **`omnyshell drive` mounts directories and git repos onto remote node paths
  (OmnyDrive integration).** A new command group binds a local directory — or a
  git repository — to a path on a connected node and synchronizes the two over
  the same authenticated `wss` session (no extra ports or credentials). Built on
  [OmnyDrive](https://github.com/OmnyGrid/omnydrive): content-addressed manifests
  and explicit conflict detection (never a silent merge).
  - `drive mount <local-dir> <node>:<remote-path>` (and `--git <url>` with
    `--branch`/`--depth`) creates a mount; `--rw` makes the node mirror writable,
    `--name` overrides the mount name, `--no-initial-sync` skips the first push.
  - `drive ls`, `drive status <id>` inspect mounts (read local state, no Hub);
    `drive sync <id>` (`--push`/`--pull`/auto) synchronizes once; `drive watch
    <id>` (`--interval`/`--debounce`) auto-syncs live on filesystem changes.
  - `drive resolve <id>` (`--accept-local`/`--accept-origin`/`--reclone`) clears a
    conflict; `drive unmount <id>` (`--sync-first`, `--no-keep-remote`) tears one
    down; `drive remount <id>` re-establishes it after a node/CLI restart.
  - Direction is automatic: read-only mounts push, read-write mounts push/pull/no-op
    based on which side changed; a two-sided change surfaces a conflict instead of
    clobbering work.
  - Transport: a new `SessionMode.drive` carries a framed request/response RPC
    (`NodeDriveService` on the node serves a sandboxed content source and git ops;
    the client runs OmnyDrive's directory synchronizer against a
    `ChannelContentSource`). Mount state persists in `~/.omnyshell/mounts.json`.
  - Nodes advertise a `drive` capability and accept mounts by default; the
    `NodeConfig.driveEnabled` / `driveRoots` options gate and path-restrict them.
  - New client APIs: `DriveManager`, `MountStore`/`MountRecord`,
    `ChannelContentSource`, `DriveRpcClient`.

## 1.1.0

### Added

- **`omnyshell cert gen` generates the TLS files a Hub needs.** A new `cert gen`
  command builds a local CA and a Hub server certificate signed by it, writing
  `ca.crt` / `ca.key` / `server.crt` / `server.key` — the set the Hub uses
  (`hub start --cert/--key`) and that nodes and clients trust (`--ca`). Options:
  `--out` (output directory, default `certs`), `--host` (repeatable, adds SAN
  entries beyond the default `localhost`/`127.0.0.1`), `--cn`, `--days`,
  `--ca-days`, and `--force` (overwrite existing certs). It is the built-in
  equivalent of the `tool/gen-dev-certs.sh` script; both shell out to `openssl`,
  which must be on `PATH`. The generation logic is also exposed in the API as
  `CertGenerator`.

## 1.0.0

### Added

- **`:download` can fetch a remote path as a compressed archive.** Pass `--gz` or
  `--zip` for a file, or `--tar.gz` or `--zip` for a directory, e.g. `:download
  /var/log --tar.gz` or `:download /etc/hosts --gz`. The archive is built on the
  node (via `gzip`/`tar`/`zip` in a temp file, removed afterward) so only the
  compressed bytes are transferred. The local file is named `<base>.<ext>` by
  default, or written into a destination directory / explicit path if given.
  Invalid combinations (e.g. `--gz` on a directory) and missing remote tools are
  reported clearly. Plain `:download` is unchanged.

- **`:ping` accepts a count**, e.g. `:ping 3` sends three pings in sequence and
  prints each round-trip plus a `min · avg · max` summary. `:ping` with no
  argument behaves as before (a single ping).

- **Prefix-aware history search in `connect`.** When you have typed something at
  the prompt, Up/Down now walk only the history entries that start with that
  prefix (the text before the cursor), newest-first — e.g. type `git ` then press
  Up to cycle just your previous `git` commands. With an empty line it behaves as
  before, walking all entries; editing the line recomputes the prefix.

- **TAB completion in `connect`, like a normal `ssh` shell.** Pressing Tab now
  completes the word under the cursor: command names (first word) are resolved by
  scanning the node's `$PATH`, and arguments are completed as file/directory
  paths (directories get a trailing `/`). A unique match is inserted (with a
  trailing space for non-directories); several matches complete the longest
  common prefix, and pressing Tab again lists them. Candidates are produced by a
  one-off remote `exec` run in the session's current directory (portable POSIX
  `sh`, no `bash`-only `compgen`), so relative paths resolve correctly.

### Fixed

- **Interactive confirmation prompts now work (e.g. `:download`'s "Proceed? [y/N]").**
  The line editor previously paused all input while a local command was running,
  so the answer line could never be read — the prompt appeared to ignore `y` +
  Enter. Prompts are now read through the editor directly while a command is in
  flight; Ctrl-C cancels a prompt (counts as "no"), and non-interactive sessions
  auto-proceed. Stray keystrokes during a running transfer are still ignored.

- **The cwd/git prompt marker no longer interferes with foreground programs.**
  When a command launches an interactive program (editor/pager/monitor such as
  `nano`/`vim`/`less`/`top`, or a bare REPL like `python`/`node`), the `connect`
  client now switches to raw passthrough immediately — detected from the typed
  command, not just from the alternate-screen output sequence. This fixes the
  marker being injected into the program's stdin (e.g. on each Enter inside
  `nano`) on backends where the alternate screen is never reported to the client,
  such as the macOS `script(1)` PTY whose stdout is not a tty. The Ctrl-C prompt
  resync is likewise suppressed while a foreground program owns the terminal.

- **Enter is now recognised inside remote full-screen apps and their prompts**
  (e.g. confirming nano's "File Name to Write" on `Ctrl-X`). Raw passthrough now
  forwards the Enter key as a carriage return (`\r`), matching `ssh`: Dart's raw
  mode leaves `ICRNL` enabled, so the local terminal delivers Enter as `\n`,
  which some apps accept in their editor body but ignore at status-bar prompts.

### Changed

- **No `git` queries after read-only commands.** Commands that cannot change the
  working directory or git state (e.g. `ls`, `cat`, `pwd`, `git
  status`/`log`/`diff`) now enqueue a lightweight completion *ping* instead of
  the full cwd/git marker: the prompt still repaints in the right place (after
  the command's output) and keeps its current cwd/branch/status, but the remote
  no longer runs `git rev-parse`/`git status`. Blank input lines repaint the
  prompt locally with no remote round-trip at all.

### Removed

- **Disabled the `portable_pty`/native PTY backend**: the PTY exports are removed.

### Added

- **Default PTY backend now uses the system `script(1)` utility — no FFI, no
  native library.** Nodes serve interactive `connect` shells on a real
  pseudo-terminal allocated by the OS `script` command, launched as an ordinary
  child process. The child gets a genuine tty (`isatty()` true; full-screen apps
  like `vim`/`htop` work) at the client's requested geometry. Selectable via
  `node start --pty-backend script|native|none` (default `script`). This avoids
  the native `portable_pty` crash entirely. Trade-off: this backend cannot
  propagate live resize (`SIGWINCH`) to the remote terminal — only the initial
  geometry is honoured; use `--pty-backend native` if you need live resize.
  The client still advertises its local `TERM`/columns/rows when opening the
  session; when no PTY is available (Windows, or `script` missing) the node falls
  back to the pipe-based shell and conveys the initial geometry via
  `TERM`/`COLUMNS`/`LINES` environment variables.

- **Command history keyed by node UID, with change detection.** Interactive
  history is now scoped to the node's deterministic UID rather than its logical
  id, under `~/.omnyshell/history/<user>@<nodeUid>.history`. The last-seen UID
  for each `<user>@<node>` connection target is tracked under
  `~/.omnyshell/node-uids/`; when a node reconnects with a **changed UID** the
  user is alerted and — interactively — prompted whether to **migrate** the prior
  UID's history into the new UID's history (non-interactive sessions migrate
  automatically). The old history file is always left intact as a backup. Nodes
  that report no UID fall back to the legacy `<user>@<node>` key.

- **Deterministic global UIDs for nodes and hubs.** Each node and hub now derives
  a stable identifier from its own identity material rather than a random/time
  seed, so the same machine resolves to the same UID on every start and across
  hubs. A **node UID** (`nod_…`) combines the node's Ed25519 public key (empty for
  token/keyless nodes) with stable hardware/platform attributes — a per-OS
  machine id (`/etc/machine-id`, macOS `IOPlatformUUID`, Windows `MachineGuid`),
  os, arch and hostname. A **hub UID** (`hub_…`) combines the TLS certificate's
  public key (SPKI, so it survives cert renewal when the keypair is reused) with
  the same hardware/platform attributes. Inputs are length-prefixed (TLV) and
  SHA-256 hashed under a per-kind domain-separation tag, then rendered as URL-safe
  base64 — every UID is also a valid node id. The UID is **persisted under
  `~/.omnyshell/{node,hub}.uid`, recomputed on every start, and a change is
  reported loudly** (the previous value is retired into the file's history). The
  node advertises its UID in `node.register` (surfaced in discovery and `:info`);
  the hub advertises its UID in the challenge `hello` so peers can identify and
  pin it. Both are printed at startup by the CLI.

- **Command history with arrow-key navigation.** While connected to a node, the
  interactive prompt now supports a real line editor: **Up/Down** walk
  backward/forward through previously entered commands, and **Left/Right**,
  **Home/End** (also `Ctrl-A`/`Ctrl-E`), **Backspace**, **Delete**, `Ctrl-C`
  (discard line) and `Ctrl-D` (EOF on an empty line) edit the line. History is
  **persisted per node + user** under `~/.omnyshell/history/` (mode `600`), so
  different nodes or principals never share a history; blank
  lines and consecutive duplicates are skipped and the file is capped at 1000
  entries. Both remote shell commands and local `:commands` are recorded;
  confirmation-prompt answers are not. The prompt switches stdin to raw mode on a
  TTY and restores it on exit; piped/non-interactive input falls back to plain
  line reading with history disabled.

### Changed

- **`connect` banners now span the full terminal width.** The welcome banner's
  horizontal rules stretch to the terminal width (no longer capped at 72 columns),
  and exiting/disconnecting now prints a full-width rule before `Session closed`,
  visually separating the finalized session from the local terminal output. The
  closing line also names where you were connected (`Session closed (exit 0) ·
  <node> @ <hub>`).

- **`connect` prompt colors refreshed.** The working directory is now cyan and
  the git segment is blue with a red branch name and green status counts (was a
  blue cwd and a yellow git segment).

- **The `portable_pty` (FFI) PTY backend is temporarily deprecated.**
  `PtyShellBackend`/`PtyShellSession` are retained and still opt-in via
  `node start --pty-backend native` (they support live resize), but are no longer
  the default: the underlying native library has a `SIGCHLD`-handler memory-safety
  bug that races the Dart VM's child reaper and can intermittently crash the node
  (`EXC_BAD_ACCESS` inside `portable_pty_open`). Reported upstream; once fixed this
  backend will be promoted back to the default and the deprecation removed.

### Fixed

- **Ctrl-C interrupts the remote command instead of closing `connect`.** Raw mode
  clears `ICANON` but not `ISIG`, so the terminal raised `SIGINT` on Ctrl-C and
  terminated omnyshell before the keystroke ever reached the line editor.
  Interactive sessions now intercept `SIGINT` at the process level (so omnyshell
  stays alive) and relay it to the remote foreground command, discarding the
  local input line first (or passing straight through to a full-screen app). The
  remote shell installs a no-op `INT` trap at session start so it survives the
  signal — interrupting a running command without killing the (non-interactive)
  shell, while the command itself still receives the default disposition and
  stops. Non-interactive runs keep the default behaviour so a scripted session
  can still be killed with Ctrl-C.

- **Full-screen apps (`nano`/`vim`/`less`/`top`) now work over `connect`.** Two
  problems are fixed. (1) The cwd-marker `printf` was sent on its own line right
  after the command, so the non-interactive remote shell left it in the PTY input
  buffer where a foreground program read it as typed input (every newline in
  `nano` echoed the marker, and a stray `pico.save` could appear). The command and
  marker are now sent as one logical line — `eval '<cmd>' ; <marker>` — so the
  shell consumes both before executing; the marker runs only after the command/app
  exits. `eval` keeps this valid for any command (pipes, trailing `&`, `cd`).
  (2) The client line editor kept buffering keystrokes while a full-screen app was
  running. The client now watches the output stream for the alternate-screen
  sequences (`ESC[?1049h`/`ESC[?1049l`) and, while the app owns the screen,
  switches the editor to raw passthrough so keystrokes reach the app verbatim;
  on exit it restores local line editing and repaints the prompt. (Non-alternate-
  screen interactive programs such as a bare REPL still have no client-observable
  signal and remain best-effort.)

- **`connect` no longer shows the remote shell's own prompt over a real PTY.**
  On a PTY the node's shell ran interactively and printed its own PS1/theme prompt
  and echoed every keystroke — duplicating the client's managed prompt. The
  `script(1)` backend now runs the shell **non-interactively** for `shell` mode,
  reading its command stream from `/dev/stdin` with terminal echo disabled, so the
  client's prompt is the only one shown. A real PTY is still allocated (full-screen
  apps and the requested geometry keep working), matching the prompt-free behaviour
  of the pipe fallback the `CwdMarker` design assumes.

- **Prompt no longer corrupts the cursor on a real PTY.** A PTY's `ONLCR` rewrites
  the cwd-marker line's trailing `\n` as `\r\n`; the stray `\r` was captured as the
  marker's last (privilege) field, so a non-root session rendered `(⚠ \r)` into the
  prompt and the carriage return jumped the cursor to column 0. The marker parser
  now drops a trailing `\r` before splitting fields.

- **PTY sessions now terminate correctly on Linux.** The `portable_pty` native
  library keeps the pty slave fd open for the handle's lifetime, so on Linux the
  master never reports EOF after the child exits (macOS does), leaving the output
  stream open forever — interactive sessions appeared to hang and the real-PTY
  tests timed out on CI. The session now detects child exit explicitly via
  `tryWait()` once all readable output has drained, instead of relying solely on
  master EOF.

## 0.3.0

### Changed

- **Local commands now use a `:` prefix** (`:help`, `:info`, `:exit`, …) instead
  of `/`. The old `/` prefix collided with ordinary shell input that legitimately
  starts with `/` — most notably absolute binary paths such as `/bin/bash`, which
  were intercepted as unknown local commands instead of running. A colon never
  begins a real shell command, so local commands and remote shell input are no
  longer ambiguous. **Breaking:** scripts or muscle-memory using `/help`, `/exit`,
  etc. must switch to `:help`, `:exit`.

### Added

- **`:download` / `:upload` file transfer.** Inside an interactive session,
  `:download <remotePath> [localDest]` and `:upload <localPath> [remoteDest]`
  move files and directories between the client and the node. Transfers run over
  a **separate, parallel Hub connection** (a dedicated `transfer`-mode session),
  so the interactive shell stays responsive. The payload is streamed per file and
  compressed with **GZip level 4** (built-in `dart:io` codec), **resumable** by
  byte offset (re-run to continue a partial copy), and every file's **SHA-256 is
  verified** end-to-end — a mismatch drops the file so a re-run fetches it
  cleanly. Implemented purely over the existing binary channel + credit-window
  flow control, with no Hub changes (handshake/metadata ride a self-framed record
  stream on stdin/stdout). A progress bar is shown on a TTY.
  - **Destination may be a file or a directory** (`cp`/`scp` semantics, resolved
    on the receiving side): an existing directory or a path ending in `/` means
    *write into it* (keeping the source's top-level name); otherwise the
    destination names the result itself (a single file is written to exactly that
    path; a directory copied onto a non-existent path becomes the new root);
    copying a directory onto an existing file is refused.
  - **Pre-transfer confirmation** spells out the resolved destination, the chosen
    mode, and the exact target path of each file (tagged `new` / `overwrite` /
    `resume`) before anything is written.
- **Git branch, status, and privilege in the prompt.** When the remote working
  directory is git-managed, the `connect` prompt now shows the branch and a
  compact status — `user@node:cwd git(branch +S ~M ?U) $` — where `+S ~M ?U`
  counts staged/modified/untracked files and appears only when there are changes.
  A superuser session also shows a `(⚠ root)` indicator. Both are gathered over
  the existing per-command `$PWD` marker (no extra round trip) and ANSI-colorized
  on a TTY (branch yellow, status counts red, root warning bold red; `NO_COLOR`
  honored).
- **Welcome banner on `connect`.** Opening an interactive session now prints a
  rule-separated welcome banner summarizing the connection: the OmnyShell CLI
  version, the node (id, display name, online status, platform, hostname, agent
  version), advertised capabilities (shells, features, max sessions), operator
  labels, the authenticated user and roles, the Hub URL, measured round-trip
  latency, and the session id/mode. Colorized on a TTY (honors `NO_COLOR`) and
  falls back to a plain banner when piped.
- **`login` / `logout` commands.** `omnyshell login` authenticates to a Hub once
  (verifying the credentials with a real auth handshake) and saves the session to
  `~/.omnyshell/credentials.json` (file mode `600`). Subsequent client commands
  (`connect`, `exec`, `nodes list`, `whoami`) then run without credential flags.
  Sessions are keyed by Hub URL with a remembered default, so multiple Hubs are
  supported; explicit `--principal`/`--token`/`--key` still take precedence.
  `omnyshell logout` removes a saved session (`--hub`) or all of them (`--all`).
  Key-based logins reference the existing Ed25519 seed file by path rather than
  copying the secret.

### Documentation

- Document the `login` / `logout` flow and the credential-free command usage in
  the README, and refresh the badge row (status, tag, commits, PRs, code size).

## 0.2.0

### Added

- **Interactive prompt line.** `omnyshell connect` now shows a `user@node:cwd $`
  prompt before each command. The working directory is tracked live via
  lightweight shell integration (a hidden per-session marker that reports `$PWD`
  after each command), and the prompt is ANSI-colorized when stdout is a TTY
  (honoring `NO_COLOR`).

## 0.1.0

Initial release — Stage 1: secure core and a working `Client → Hub → Node`
vertical slice.

### Added

- **Hub-centric architecture.** Clients connect to a Hub by node identity, not
  by `host:port`. The Hub discovers nodes, authenticates and authorizes
  principals, and brokers sessions.
- **WebSocket-on-TLS transport.** All connections are encrypted; there is no
  plaintext or raw-TCP mode. Nodes dial the Hub outbound and hold a persistent
  control connection (NAT-friendly).
- **Multiplexed channel protocol.** SSH-channel-style multiplexing over a single
  connection: JSON control messages on WebSocket text frames, binary stream data
  (stdin/stdout/stderr) behind a compact 10-byte header on binary frames.
- **Pluggable authentication.** `Authenticator` contract with two
  implementations: `PublicKeyAuthenticator` (Ed25519, `authorized_keys`-style,
  replay-resistant nonce challenge) and `TokenAuthenticator` (bearer).
- **Authorization.** `Authorizer` contract with a default role-based
  implementation enforced by the Hub on every session open.
- **Node runtime.** Connect → authenticate → register → advertise capabilities →
  serve sessions, with automatic reconnect and exponential backoff.
- **Hub broker.** `NodeRegistry`, `SessionRouter` (tunnel relay), and a
  `Clock`-driven `HeartbeatMonitor`.
- **Client SDK.** `execute()` for one-shot commands and `startInteractiveShell()`
  for real-time streaming sessions, plus an extensible local `/` command system.
- **Process shell backend.** `ProcessShellBackend` runs commands via
  `Process.start` behind a `ShellBackend` interface (PTY backend can plug in
  later).
- **CLI.** `omnyshell hub start`, `node start`, `connect`, `exec`, `nodes list`,
  and `whoami`, all built on the public Dart APIs.
- **Tests.** Unit, integration and end-to-end coverage over real `wss` loopback
  connections with a self-signed test certificate.
