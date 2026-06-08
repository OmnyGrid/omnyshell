## Unreleased

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

- **The `portable_pty` (FFI) PTY backend is temporarily deprecated.**
  `PtyShellBackend`/`PtyShellSession` are retained and still opt-in via
  `node start --pty-backend native` (they support live resize), but are no longer
  the default: the underlying native library has a `SIGCHLD`-handler memory-safety
  bug that races the Dart VM's child reaper and can intermittently crash the node
  (`EXC_BAD_ACCESS` inside `portable_pty_open`). Reported upstream; once fixed this
  backend will be promoted back to the default and the deprecation removed.

### Fixed

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
