# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- **Local commands now use a `:` prefix** (`:help`, `:info`, `:exit`, …) instead
  of `/`. The old `/` prefix collided with ordinary shell input that legitimately
  starts with `/` — most notably absolute binary paths such as `/bin/bash`, which
  were intercepted as unknown local commands instead of running. A colon never
  begins a real shell command, so local commands and remote shell input are no
  longer ambiguous. **Breaking:** scripts or muscle-memory using `/help`, `/exit`,
  etc. must switch to `:help`, `:exit`.

### Added

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
