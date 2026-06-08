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

### Fixed

- **Nodes now report their real OmnyShell version.** `NodeConfig.agentVersion`
  defaults to `omnyShellVersion` instead of a hardcoded `0.1.0`, so a node's
  advertised `Agent:` version (shown in `:info` and node details) reflects the
  actual build. `omnyShellVersion` is now the single source of truth and is kept
  in sync with `pubspec.yaml`, guarded by a new `version`-tagged test.

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
