# omnyshell

[![pub package](https://img.shields.io/pub/v/omnyshell.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/omnyshell)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/OmnyGrid/omnyshell/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/OmnyGrid/omnyshell/actions/workflows/dart.yml)
[![GitHub Tag](https://img.shields.io/github/v/tag/OmnyGrid/omnyshell?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyshell/releases)
[![New Commits](https://img.shields.io/github/commits-since/OmnyGrid/omnyshell/latest?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyshell/network)
[![Last Commits](https://img.shields.io/github/last-commit/OmnyGrid/omnyshell?logo=git&logoColor=white)](https://github.com/OmnyGrid/omnyshell/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/OmnyGrid/omnyshell?logo=github&logoColor=white)](https://github.com/OmnyGrid/omnyshell/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/OmnyGrid/omnyshell?logo=github&logoColor=white)](https://github.com/OmnyGrid/omnyshell)
[![License](https://img.shields.io/github/license/OmnyGrid/omnyshell?logo=open-source-initiative&logoColor=green)](https://github.com/OmnyGrid/omnyshell/blob/master/LICENSE)

A **secure, Hub-centric remote shell platform** written in **pure Dart**.
Inspired by SSH, but instead of connecting to a `host:port` you connect to a
**Hub** by **node identity**. The Hub discovers nodes, authenticates and
authorizes principals, and brokers an encrypted session to the right node —
which may be behind NAT, since nodes dial the Hub outbound.

```text
Traditional SSH        OmnyShell
Client ──► Host:Port    Client ──► Hub ──► Node
```

```sh
omnyshell connect worker-prod-01
omnyshell exec database-server "uname -a"
```

All transport is **WebSocket-on-TLS (`wss`)** — there is **no plaintext or raw
TCP mode**. Authentication is pluggable (Ed25519 public keys or bearer tokens),
authorization is enforced by the Hub, and the whole platform is available both
as **first-class Dart APIs** and as the **`omnyshell` CLI**.

It also has a built-in, **provider-agnostic AI agent**: type `:ai <prompt>` in a
session and an agent (Anthropic, OpenAI or Gemini, with your own API key)
investigates the node, plans, and runs the commands needed to accomplish a
natural-language goal — gated by `command_shield` and running right inside the
live shell.

## API Documentation

See the [API Documentation][api_doc] for the full list of classes and APIs.

[api_doc]: https://pub.dev/documentation/omnyshell/latest/

## Features

- **AI agent.** A provider-agnostic `:ai <prompt>` command drives an AI agent
  that investigates the connected node, plans, and runs commands to accomplish a
  natural-language goal — right inside the live shell session, sharing its PTY,
  cwd, env and cached sudo. Bring your own key for **Anthropic**, **OpenAI** or
  **Gemini**; pick `standard` (confirm each command), `plan` (approve a multi-step
  plan) or `auto` (autonomous). Every command is scored by
  [`command_shield`][command_shield] first, so DENY/critical commands are blocked
  in every mode. The agent core is pure Dart and exported from the web barrel, so
  a browser client can drive it too.
- **Hub-centric.** Connect by node identity, not by network location. The Hub is
  service discovery, authentication, authorization, session broker and tunnel
  coordinator in one.
- **Secure by default.** Every connection is WebSocket-on-TLS. There is no
  insecure mode. Login is replay-resistant (the Hub challenges each connection
  with a single-use nonce that public-key clients must sign).
- **Pluggable authentication.** `Authenticator` contract with
  `PublicKeyAuthenticator` (Ed25519, `authorized_keys`-style) and
  `TokenAuthenticator` (bearer), or compose both.
- **Persisted login.** `omnyshell login` authenticates to a Hub once and saves
  the session to `~/.omnyshell/credentials.json` (mode `600`), so every other
  command runs without credential flags. Sessions are keyed by Hub URL with a
  remembered default, so you can switch between Hubs; `omnyshell logout` clears
  one or all of them.
- **Role-based authorization.** The Hub authorizes every session open; the
  bundled `RoleBasedAuthorizer` fails closed.
- **NAT-friendly tunnels.** Nodes dial the Hub outbound and hold a persistent
  connection; the Hub multiplexes sessions over it and relays bytes.
- **Real-time interactive shells & exec.** Streaming stdin/stdout/stderr, exit
  code propagation, terminal resize and interrupt signals, plus an extensible
  local `:command` system. The `connect` prompt is a full line editor with
  persistent per-node history, prefix-aware history search, and `ssh`-style TAB
  completion of commands and remote paths.
- **File transfer.** `:download` / `:upload` move files and directories over a
  separate parallel Hub connection, with GZip-compressed, resumable,
  SHA-256-verified streaming — and optional on-node `--gz`/`--zip`/`--tar.gz`
  archiving.
- **TCP tunnels / port forwarding.** Expose an internal TCP port — a connected
  node's, or your own machine's — on a public port of the Hub, so external
  clients reach e.g. a localhost HTTP server through `hub-host:PUBLIC_PORT`.
  Bytes ride the existing multiplexed `wss` connection (no extra plane); the Hub
  binds the public listener within an operator-configured range
  (`--tunnel-port-range 20000-20100`, fail-closed when unset) and authorizes each
  open with the same `RoleBasedAuthorizer`. Use `omnyshell tunnel open <node>
  <port>` (or `--local <port>`), the in-session `:tunnel <port>` command, and
  `omnyshell tunnel list` / `close`. Built on [`tcp_tunnel`][tcp_tunnel]'s
  `PortRange`.
- **Drive mounts (OmnyDrive).** `omnyshell drive` mounts a local directory — or a
  git repository — onto a path on a connected node and keeps the two in sync over
  the same `wss` transport. Built on [OmnyDrive][omnydrive]: content-addressed
  manifests, explicit conflict detection (never a silent merge), one-shot `sync`
  or live `watch`, and per-mount read-only/read-write control. Mount state
  persists in `~/.omnyshell/mounts.json`.
- **Reliable.** Heartbeats with a Clock-driven watchdog, automatic node
  reconnect with exponential backoff, and end-to-end backpressure.
- **Observable.** Structured audit log, hub metrics, and a discovery API.
- **Three first-class APIs + a CLI.** Embed a Hub, a Node or a Client, or run
  the `omnyshell` binary — all built on the same shared core.
- **Tested.** Unit, integration and end-to-end coverage over real `wss`
  loopback connections.

## Architecture

```text
                OmnyShell Core (protocol + domain)
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
     Hub API           Node API          Client API
        │                 │                 │
        └─────────────────┼─────────────────┘
                          │
                         CLI
```

Clients and nodes both speak one multiplexed protocol over a single `wss`
connection. Control messages travel as JSON on WebSocket **text** frames; stream
data (stdin/stdout/stderr) travels as binary frames behind a compact 10-byte
header — SSH-channel-style multiplexing. The Hub relays a session by rewriting
the channel id between the client and node ends, never inspecting the bytes.

```text
lib/
├── omnyshell.dart          # shared protocol + domain contracts
├── omnyshell_hub.dart      # Hub composition root
├── omnyshell_node.dart     # Node runtime
├── omnyshell_client.dart   # Client SDK
└── src/
    ├── domain/             # value objects, entities, auth & backend contracts
    ├── protocol/           # frames, control messages, codec, channels, mux
    ├── infrastructure/     # wss transport, process backend, authenticators
    ├── application/        # node runtime, hub broker, client runtime, CLI logic
    └── shared/             # errors, clock, id/bytes helpers, JSON helpers
```

## Getting started

```yaml
dependencies:
  omnyshell: ^1.0.0
```

OmnyShell uses `dart:io` for TLS, sockets and process execution, so it runs on
any non-web Dart target. A TLS server certificate is required to run a Hub.

## Usage

### Local development quick start

The Hub needs a TLS certificate and key (there is no plaintext mode). For local
use, generate a throwaway dev CA + server certificate and start a Hub:

```sh
omnyshell cert gen               # writes certs/{ca,server}.{crt,key} (built-in)
./run-hub.sh                     # generates certs if missing, then starts the Hub
```

`omnyshell cert gen` builds a local CA and a Hub server certificate signed by it
(`--out` directory, `--host` to add SAN entries, `--force` to regenerate). It is
the built-in equivalent of the `tool/gen-dev-certs.sh` script (which remains for
repo checkouts); both shell out to `openssl`.

`run-hub.sh` starts a Hub on `wss://127.0.0.1:8443` with two demo grants
(`alice:s3cr3t:admin` and `noded:nodetok:node`). In other shells, attach a node
and run a command — pass `--ca certs/ca.crt` so the dev certificate is trusted:

```sh
dart run bin/omnyshell.dart node start --hub wss://127.0.0.1:8443 \
  --id local-01 --label allow-roles=admin \
  --principal noded --token nodetok --ca certs/ca.crt

dart run bin/omnyshell.dart exec local-01 "uname -a" --hub wss://127.0.0.1:8443 \
  --principal alice --token s3cr3t --ca certs/ca.crt

dart run bin/omnyshell.dart connect local-01 --hub wss://127.0.0.1:8443 \
  --principal alice --token s3cr3t --ca certs/ca.crt
```

> **Why a CA, not a bare self-signed cert?** A self-signed *leaf* certificate
> used as its own trust anchor is rejected by Dart's TLS stack when a client
> verifies it. `tool/gen-dev-certs.sh` therefore creates a small local CA and a
> server certificate signed by it (with the `keyCertSign`/`serverAuth` usages
> Dart requires). Clients trust the CA via `--ca certs/ca.crt`. For production,
> use a certificate from a real CA.
>
> **`--ca` tolerates hostname mismatches.** The Hub certificate is verified
> against the pinned CA, but the hostname/SAN check is skipped — so a dev hub
> reached by an IP or an alias not listed in the certificate's SANs still
> verifies (the connection is rejected if the certificate isn't issued by your
> CA). This means `--insecure-skip-verify` — which disables *all* verification
> and is vulnerable to MITM — is almost never needed; prefer `--ca`.

If you only need the Hub to **start** (e.g. for embedding tests), a single
self-signed certificate is enough, since the Hub only presents it:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 365 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
dart run bin/omnyshell.dart hub start --cert cert.pem --key key.pem \
  --grant-token "alice:s3cr3t:admin"
```

### Run a Hub

```sh
omnyshell hub start \
  --host 0.0.0.0 --port 8443 \
  --cert server.crt --key server.key \
  --grant-token "alice:s3cr3t:admin" \
  --authorized-keys ./authorized_keys
```

`authorized_keys` lines are `principal base64-ed25519-key role1,role2 Name`.

#### TLS from a certificate directory (`--tls-dir`)

Instead of `--cert`/`--key`, point the Hub at a directory holding `fullchain.pem`
+ `privkey.pem` (the Let's Encrypt layout) with `--tls-dir`:

```sh
omnyshell hub start \
  --tls-dir ~/.letsencrypt/sites.menuici.com \
  --tunnel-port-range 20000-20100 \
  --grant-token "alice:s3cr3t:admin"
```

`--tls-dir` is mutually exclusive with `--cert`/`--key`. The Hub re-checks the
files periodically and, when a renewal rewrites them, **rebinds the listener with
the new certificate without a restart** — established connections drain on the old
listener while new ones are served the renewed cert. Run the Hub on a hostname the
certificate covers (e.g. `wss://sites.menuici.com:8443`), since clients verify the
name.

When `--tls-dir` is set it also supplies sensible defaults for tunnels:

- `--tunnel-tls-dir` defaults to the same directory (so secure tunnels reuse the
  cert, hot-reloaded the same way), and
- `--tunnel-public-host` defaults to the certificate's DNS name (its SAN, falling
  back to the subject CN).

Pass either flag explicitly to override the derived value.

### Run a Node

```sh
omnyshell node start \
  --hub wss://hub.example.com:8443 \
  --id worker-prod-01 \
  --label env=prod \
  --principal node-account --token "$NODE_TOKEN" \
  --ca server.crt
```

Interactive sessions are served on a **real pseudo-terminal allocated by the
system `script(1)` utility** — no FFI and no native library to install. The
child shell gets a genuine tty at the client's requested geometry, so
full-screen programs such as `nano`, `vim` and `htop` work. Select the backend
with `--pty-backend`:

```sh
omnyshell node start --pty-backend script   # default: system script(1), no native lib
omnyshell node start --pty-backend none     # pipe-based shell, env-var geometry only
```

The `script` backend honours only the **initial** geometry — it cannot
propagate live resize (`SIGWINCH`) to the remote terminal. (A `native` FFI
backend with live-resize support exists but is currently disabled pending a
fix to an upstream crash.) On platforms where `script` is unavailable (e.g.
Windows), the node transparently falls back to a pipe-based shell and conveys
the initial geometry via the `TERM`/`COLUMNS`/`LINES` environment variables.

#### Node environment profile (`~/.omnyshell/profile.yaml`)

Sessions run the node's shell **non-interactively**, so no rc file (`.zshrc`,
`.bashrc`, …) is sourced and `$PATH` starts bare. The node instead applies an
env profile at `~/.omnyshell/profile.yaml` to every shell **and** exec session:

```yaml
# ~/.omnyshell/profile.yaml — managed by `omnyshell node`
env:
  PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  EDITOR: vim          # add your own vars; they survive PATH sync
```

Values may reference others with `${VAR}` (expanded against the node's
environment, e.g. `PATH: "/opt/bin:${PATH}"`).

On an **interactive** `node start`, the node derives `PATH` from your shell rc
(it runs your login+interactive shell and reads the resulting `PATH`) and, when
it differs from the stored profile, shows the change and asks before writing:

```
Detected PATH from your shell profile (~/.zshrc):
  + /opt/homebrew/bin
  + ~/.cargo/bin
Update ~/.omnyshell/profile.yaml? [y/N]
```

Disable that prompt with `--no-profile-sync`, or point at a different file with
`--profile <path>`. A **non-interactive** start (e.g. as a service) never
modifies the profile — it loads the existing file and prints a hint. Refresh the
profile on demand with:

```sh
omnyshell node profile sync          # prompts before writing
omnyshell node profile sync --yes    # write without prompting
```

### Run as a system service

Install the Hub or Node as a native OS service (systemd on Linux, launchd on
macOS, the Service Control Manager on Windows) so it starts at boot and is
restarted on failure. This wraps
[`dart_service_manager`](https://pub.dev/packages/dart_service_manager): the flags
you pass to `service install` are the exact `hub start` / `node start` flags, and
they are captured into the service definition.

```sh
# Install + start (user scope — no elevated privileges needed):
omnyshell service install hub \
  --cert server.crt --key server.key \
  --grant-token "alice:s3cret:admin"

# …or load (and hot-reload) the certificate from a Let's Encrypt directory:
omnyshell service install hub \
  --tls-dir ~/.letsencrypt/sites.menuici.com \
  --grant-token "alice:s3cret:admin"

omnyshell service install node \
  --hub wss://hub.example.com:8443 \
  --id worker-prod-01 --label env=prod \
  --principal node-account --token "$NODE_TOKEN" --ca server.crt

# Inspect what would be installed without touching the system:
omnyshell service install hub --cert server.crt --key server.key \
  --grant-token "alice:s3cret:admin" --dry-run

# Lifecycle (role is hub|node):
omnyshell service status   hub
omnyshell service stop     hub
omnyshell service start    hub
omnyshell service restart  hub
omnyshell service uninstall hub
```

- **Scope.** Installs to the current user by default. Add `--system` to install
  machine-wide (requires `sudo`/Administrator). Under `--system` the service runs
  with `OMNYSHELL_HOME=/var/lib/omnyshell` (override with `--data-dir`) so it has a
  stable home for its UID/state files.
- **Path flags are absolutized** (`--cert`, `--key`, `--ca`, `--authorized-keys`)
  at install time, so relative paths work regardless of the service's working
  directory.
- **Flags are captured at install time.** To change them later, re-run with
  `service install --force <role> …`, or `service reconfigure <role> …` (which
  preserves the running state).
- **Secrets:** tokens passed as flags are stored in the generated unit/plist.
  Restrict access to that file, or keep tokens out of the command line by other
  means, on shared machines.
- **Windows runs a private copy.** On Windows the service runs through Task
  Scheduler (not the SCM, which kills a plain console app with error 1053). A
  `dart pub global activate` install runs as `dart <snapshot>`, and Windows
  **locks that pub-cache snapshot while the service runs** — so `service install`
  stages a private copy under `%LOCALAPPDATA%\OmnyShell\bin` (or
  `%OMNYSHELL_HOME%\bin`) and points the task there. This lets you `pub global
  activate` a new version freely; each `service install` then refreshes the copy
  to the currently-installed version (re-run `service install --force <role>` to
  pick up an upgrade).

### Log in once

`omnyshell login` authenticates to a Hub (verifying the credentials with a real
handshake) and saves the session locally, so the commands below don't need
`--hub`, `--principal`, `--token`/`--key` or `--ca` every time:

```sh
omnyshell login --hub wss://hub.example.com:8443 \
  --principal alice --token "$TOKEN" --ca server.crt

omnyshell logout                         # forget the current Hub
omnyshell logout --hub wss://...:8443     # forget a specific Hub
omnyshell logout --all                    # forget every saved session
```

The session is written to `~/.omnyshell/credentials.json` (mode `600`). Logins
are keyed by Hub URL with a remembered default, and explicit credential flags
always override the saved session. For key-based login, pass `--key` instead of
`--token`; the saved session references the seed file by path rather than
copying the secret.

The `--ca` passed at login is saved on the session and reused by later commands,
so a self-signed/dev hub keeps verifying (chain checked, hostname tolerated)
without re-passing it.

If you log in with `--insecure-skip-verify` (TLS verification disabled
entirely — prefer `--ca` instead), `login` asks whether to remember it for that
Hub:

```
Store --insecure-skip-verify so future commands to wss://… also skip TLS verification? [y/N]
```

Answer `y` to persist it on the saved session, so later commands reuse the
insecure setting without re-passing the flag; answer `n` (the default, and what
a non-interactive login assumes) to keep it one-off. Re-running `login` without
the flag, or `logout`, clears the remembered setting.

### Connect, exec and discover

After `login`, run any client command with no credential flags:

```sh
omnyshell connect worker-prod-01
omnyshell exec worker-prod-01 "uname -a"
omnyshell exec worker-prod-01 "make build" --cwd /srv/app   # set the working dir
omnyshell nodes list
omnyshell whoami
```

Or pass credentials explicitly (and target another Hub) on any single command:

```sh
omnyshell connect worker-prod-01 --hub wss://hub.example.com:8443 \
  --principal alice --token "$TOKEN" --ca server.crt
```

### Run against a local directory (`run`)

`omnyshell run` is "edit locally, build remotely, get the results back" in one
command: it mounts a local directory onto the node (pushing the files up), runs
a command **inside** that directory, then syncs whatever the command produced
back down to local. It wraps the [Drive mount](#drive-mounts-omnydrive)
machinery, so it rides the same authenticated `wss` session — no extra ports.

```sh
# Mount the current directory, build remotely, sync the build output back.
omnyshell run worker-prod-01 "make build"

# Use a specific local directory and sync back periodically while it runs.
omnyshell run worker-prod-01 "pytest" --dir ./project --sync-interval 5

# Co-mount a sibling dependency so it stays reachable by its local relative path.
omnyshell run worker-prod-01 "make" --with ../dependency-project

# Throwaway run: tear the mount down and delete the node copy when done.
omnyshell run worker-prod-01 "make" --unmount --clean-remote
```

When the command needs a sibling directory that the project references by a
relative path (e.g. a build that reads `../dependency-project`), add `--with
<dir>` (repeatable). Instead of mounting just `--dir`, `run` mounts the **nearest
common ancestor** of `--dir` and every `--with` — a *wrapper* — and runs with the
remote working directory set to `wrapper/<--dir>`, so the exact same relative
reference (`../dependency-project`) resolves on the node. Only the named
directories are synced (an `--include` whitelist is applied automatically); other
contents of the wrapper are never pushed or pulled.

By default `run` keeps the mount registered after it finishes, so you can re-run,
`omnyshell drive sync <id>`, or `omnyshell drive unmount <id>` later. The remote
mount path is ephemeral unless you pass `--mount-path`, and the command's working
directory defaults to the mount path (override with `--cwd`).

Repeated runs **reuse** a matching mount instead of re-pushing everything: a run
of the same local directory against the same node reuses the previous mount and
only syncs the changed files before running. An explicit `--mount-path` matches
on node + local dir + remote path; an ephemeral run reuses a previous ephemeral
mount for that node + local dir. Pass `--fresh` to force a brand-new mount.

The same lifecycle is available on `exec` via `--mount <local-dir>` (plus
`--mount-path`, `--mount-name`, `--initial-sync`, `--sync-interval`, `--unmount`
and `--clean-remote`); `run` is the convenience form that mounts a directory by
default.

### Drive mounts (OmnyDrive)

`omnyshell drive` mounts a local directory (or a git repository) onto a path on a
connected node and synchronizes the two. It is powered by [OmnyDrive][omnydrive]
and rides the same authenticated `wss` session as everything else — no extra
ports or credentials. Nodes advertise the `drive` capability and accept mounts by
default.

```sh
# Mount a local directory onto a node path (read-only mirror by default).
omnyshell drive mount ./site worker-prod-01:/srv/site

# Read-write mount: edits made on the node can sync back, with conflict detection.
omnyshell drive mount ./site worker-prod-01:/srv/site --rw --name site

# Mount a git repository — the node clones it, so the URL must be reachable
# from the node.
omnyshell drive mount --git https://github.com/acme/app.git \
  worker-prod-01:/srv/app --branch main
```

Restrict which sub-paths a directory mount serves with repeatable `--include`
(whitelist) / `--exclude` (wins over include) globs — the filter is baked into the
mount, so every sync keeps applying it. With **neither** flag given, the directory's
root `.omnyignore` (a gitignore-style file; blank lines and `#` comments skipped,
`!`-negation unsupported) supplies the default exclude set; `--ignore-file <name>`
picks a different file. Explicit `--include`/`--exclude` override the file entirely.

```sh
omnyshell drive mount ./app worker-prod-01:/srv/app --exclude "**/*.tmp" --exclude "build/"
omnyshell drive mount ./app worker-prod-01:/srv/app   # uses ./app/.omnyignore if present
```

The target is `<node>:<remote-path>`. The initial mount populates the node (pass
`--no-initial-sync` to skip). Inspect and synchronize mounts:

```sh
omnyshell drive ls                       # active mounts + sync state (local, no Hub)
omnyshell drive status <mount-id>        # baseline ref, status, last sync, errors
omnyshell drive sync   <mount-id>        # one-shot sync (auto direction)
omnyshell drive sync   <mount-id> --push # force local → node
omnyshell drive sync   <mount-id> --pull # force node → local
omnyshell drive watch  <mount-id>        # live auto-sync on change/interval (Ctrl-C)
```

Direction is automatic: read-only mounts **push**; read-write mounts push, pull,
or no-op based on which side changed. When **both** sides changed (or a forced
push finds the node has drifted), the sync stops with a **conflict** instead of
clobbering work — resolve it explicitly:

```sh
omnyshell drive resolve <mount-id> --accept-local    # local wins
omnyshell drive resolve <mount-id> --accept-origin   # node wins
omnyshell drive resolve <mount-id> --reclone         # re-fetch the node copy
```

Tear down or re-establish a mount:

```sh
omnyshell drive unmount <mount-id>                # forget the mount (node files kept)
omnyshell drive unmount <mount-id> --sync-first   # final sync, then forget
omnyshell drive unmount <mount-id> --no-keep-remote  # also delete node files (dir mounts)
omnyshell drive remount <mount-id>                # re-establish after a node/CLI restart
```

The mount lifecycle is `mount → mounted (clean) → syncing → {clean | conflicted |
error}`, with `watch` driving auto-syncs and `resolve` clearing a conflict. State
is persisted in `~/.omnyshell/mounts.json`, so mounts survive across CLI runs.

[omnydrive]: https://github.com/OmnyGrid/omnydrive
[tcp_tunnel]: https://pub.dev/packages/tcp_tunnel
[command_shield]: https://pub.dev/packages/command_shield

### TCP tunnels / port forwarding

`omnyshell tunnel` exposes an internal TCP port on a **public port of the Hub**,
so external clients reach an otherwise-unreachable service (a NAT'd node's
database, a localhost dev server) through `hub-host:PUBLIC_PORT`. The forwarded
bytes ride the same authenticated, multiplexed `wss` connection — there is no
extra listener on the node or new credential. The Hub binds the public port
within the operator-configured range (`hub start --tunnel-port-range
20000-20100`; tunnels are **disabled** until that range is set) and authorizes
each open with the same `RoleBasedAuthorizer`.

```sh
# Expose a connected node's TCP port (e.g. its local Postgres) on the Hub.
omnyshell tunnel open worker-prod-01 5432
omnyshell tunnel open worker-prod-01 5432 --public-port 20010   # pick the public port

# Expose *your* machine's port instead — the command stays running to serve it.
omnyshell tunnel open --local 3000

omnyshell tunnel list                    # your active tunnels (alias: ls)
omnyshell tunnel close <id>              # close by id or short-id prefix
```

`tunnel open <node> <port>` prints the public endpoint and a `tunnel close` hint;
`--local <port>` forwards in the other direction and serves until `Ctrl-C`. The
same operations are available in a `connect` session via `:tunnel` (the node is
implicit), and from the Client SDK (`openTunnel` / `listTunnels` / `closeTunnel`).

### Embed the Client SDK

```dart
import 'package:omnyshell/omnyshell_client.dart';

final client = OmnyShellClient(ClientConfig(
  hubUri: Uri.parse('wss://hub.example.com:8443'),
  credentials: TokenCredentialProvider(principal: 'alice', token: token),
));
await client.connect();

// One-shot command:
final result = await client.execute(nodeId: 'worker-prod-01', command: 'uname -a');
print('exit ${result.exitCode}\n${result.stdoutText}');

// Interactive session:
final session = await client.openSession(
  nodeId: 'worker-prod-01',
  mode: SessionMode.shell,
);
session.stdout.listen(stdout.add);
session.writeStdin(utf8.encode('ls -la\n'));
await session.exitCode;
```

### Embed a Hub or Node

```dart
final hub = OmnyShellHub(HubConfig(
  securityContext: SecurityContext()
    ..useCertificateChain('server.crt')
    ..usePrivateKey('server.key'),
  authenticator: TokenAuthenticator({'tok': TokenGrant(principal: PrincipalId('alice'))}),
));
await hub.start();

final node = OmnyShellNode(NodeConfig(
  hubUri: Uri.parse('wss://localhost:${hub.port}'),
  nodeId: NodeId('local-01'),
  credentials: TokenCredentialProvider(principal: 'node', token: 'node-tok'),
  backend: ProcessShellBackend(),
));
await node.connect();
```

See [`example/`](example/) for a complete mixed-mode (Hub + Node + Client) demo.

## AI agent (`:ai`)

`:ai <prompt>` drives a **provider-agnostic AI agent** that investigates the
connected node, plans, and runs shell commands to accomplish a natural-language
goal — without leaving the session. It is **bring-your-own-key**: you configure a
provider (**Anthropic**, **OpenAI** or **Gemini**) and an API key, and the agent
talks to that provider directly.

The agent runs its commands **in your current interactive shell session**, so they
share the live PTY, working directory, environment and cached `sudo` credentials,
and stream their output exactly as if you had typed them (it falls back to a
one-off `exec` when there is no live session). Every command the agent wants to run
is first scored by the [`command_shield`][command_shield] package; **DENY /
critical commands are auto-blocked in every mode**, independent of the confirmation
flow below.

### Modes

| Mode | Behaviour |
| --- | --- |
| `standard` | The agent proposes **one command at a time**; you confirm each before it runs. |
| `plan` (default) | The agent first investigates, then presents a **full multi-step plan** you approve all-at-once or step-by-step. |
| `auto` | The agent runs **autonomously** with no confirmation (`command_shield` still blocks DENY/critical commands). |

### Configure the agent

Configure once with `omnyshell ai` (stored in `~/.omnyshell/ai.yaml`, mode `600`),
or set the provider's API-key environment variable (`ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GEMINI_API_KEY`):

```sh
# Pick a provider and key (each provider ships sensible default models).
omnyshell ai config --provider anthropic --key sk-ant-...
omnyshell ai config --key -                 # read the key from a hidden prompt

# Optional: a stronger model for planning and a cheaper one for execution.
omnyshell ai config --planner-model claude-sonnet-4-6 --executor-model claude-haiku-4-5
omnyshell ai config --model default         # clear an override, use the default

omnyshell ai config --mode auto             # default mode
omnyshell ai config --language portuguese   # reply language (prose only)

omnyshell ai show                           # resolved config (key masked)
omnyshell ai test                           # validate the key/models with a live request
```

### Use it in a session

Inside `omnyshell connect`, type `:ai` followed by what you want done:

```text
worker-prod-01:~$ :ai why is nginx returning 502 and fix it if you can

ai ▸ investigating…
  $ systemctl is-active nginx
    active
  $ ss -ltnp | grep :8080
    (no output)
ai ▸ Plan:
  1. Confirm the upstream app on :8080 is down       (read-only)
  2. Restart the app service                          systemctl restart app
  3. Re-check nginx responds 200                       curl -sI localhost
Approve plan? [a]ll / [s]tep-by-step / [t]alk / [N]o / [q]=abort: a
  $ systemctl restart app
  $ curl -sI localhost
    HTTP/1.1 200 OK
ai ▸ Done — the app process had exited; restarting it cleared the 502.
```

Other in-session forms:

```text
:ai mode <standard|plan|auto>        # change the default mode for this session
:ai --auto <prompt>                  # one-shot mode override for this run
:ai lang <language|off>              # set/clear the reply language
:ai --lang <language> <prompt>       # one-shot language override
:ai status                           # show provider, model(s), mode, language
:ai -h | --help                      # usage
```

While a run is in progress, **Ctrl-C** requests an abort (confirmed by the loop)
and an `abort`/`q` answer at any prompt aborts immediately. At a command
confirmation, answer `?` to have the agent **explain** the command before you
decide; at plan approval, `t` (talk) sends the agent free-form notes. If a command
fails, the agent replans and re-confirms rather than barrelling ahead.

If no provider/key is configured, `:ai` prints setup instructions instead of
running.

## Interactive shell

`omnyshell connect` runs a managed line editor over the remote shell, much like
`ssh`:

- **History** is persisted per node + user under `~/.omnyshell/history/` (mode
  `600`) and keyed by the node's deterministic UID, so a node that changes
  identity can migrate its history. **Up/Down** walk it; **Left/Right**,
  **Home/End** (`Ctrl-A`/`Ctrl-E`), **Backspace**, **Delete** and `Ctrl-C`
  (discard line) / `Ctrl-D` (EOF on empty line) edit it.
- **Prefix-aware history** — with text already typed, Up/Down walk only the
  entries that start with that prefix (e.g. type `git ` then Up).
- **TAB completion** — completes the command name (first word, resolved from the
  node's `$PATH`) or an argument as a file/directory path, with longest-common-
  prefix completion and a second-Tab listing.
- **Ctrl-C** interrupts the running remote command instead of closing `connect`.

Full-screen programs (`nano`, `vim`, `less`, `top`, REPLs) get raw passthrough
so the terminal behaves as expected.

### Local shell (no Hub)

`omnyshell local` opens the **same** interactive terminal on *this* machine,
running the shell directly — no Hub, no Node, no network:

```sh
omnyshell local                    # uses $SHELL, a script(1) PTY
omnyshell local --shell bash       # pick the shell
omnyshell local --pty-backend none # pipe shell with env-var geometry
```

It is the full experience minus the network: a managed line editor, history
(under `~/.omnyshell/history/`, keyed `local@<host>`), TAB completion, the
prompt with cwd/git/privilege, and the AI agent (`:ai`). The Hub-only local
commands (`:ping`, `:latency`, `:tunnel`, `:detach`, `:tree`) are not shown,
since there is nothing remote to reach. `:ai` works with just an API key (an
`ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`GEMINI_API_KEY` env var or
`~/.omnyshell/ai.yaml`) and runs its commands in the live local shell.

## Local commands

Inside an interactive session, lines beginning with `:` are **local** OmnyShell
commands and are never sent to the remote shell:

```text
:help  :info  :node  :host  :os  :arch  :session  :capabilities
:latency  :ping [count]  :whoami  :tree  :download  :upload  :tunnel  :drive
:ai  :detach  :exit
```

`:ping` accepts an optional count (e.g. `:ping 3`) and prints each round-trip
plus a `min · avg · max` summary.

Using `:` (rather than `/`) as the prefix keeps local commands from colliding
with real shell input that legitimately starts with `/`, such as absolute paths
like `/bin/bash`.

The local-command system is extensible — third-party packages can register
custom `LocalCommand`s with a `LocalCommandRegistry`.

### File transfer (`:download` / `:upload`)

```text
:download <remotePath> [localDest] [--gz|--zip|--tar.gz]   # remote file/dir → local path or dir (default: .)
:upload   <localPath>  [remoteDest]                        # local file/dir → remote path or dir (default: cwd)
```

`:download` can fetch a remote path as a **compressed archive** built on the
node: `--gz` for a single file, or `--tar.gz` / `--zip` for a directory (so only
the compressed bytes cross the wire). The local file is named `<base>.<ext>` by
default. Invalid combinations (e.g. `--gz` on a directory) and missing remote
tools are reported clearly; plain `:download` is unchanged.

Both move files over a **separate, parallel connection to the Hub**, so the
interactive shell stays responsive during a transfer. The payload is streamed
per-file and compressed with **GZip level 4**; transfers are **resumable** (re-run
to continue a partial copy) and every file's **SHA-256 is verified** end-to-end —
a mismatch drops the bad file so a re-run fetches it cleanly. Relative remote
paths resolve against the current remote working directory.

**The destination may be a directory or an explicit target path** (`cp`/`scp`
semantics, resolved on the receiving side):

- an **existing directory**, or a path ending in `/`, means *write into it* —
  the source keeps its top-level name (`:download /srv/foo ./out` → `./out/foo/…`);
- otherwise the destination **names the result itself** — a single file is
  written to exactly that path (`:upload ./a.txt /srv/g.txt` → `/srv/g.txt`), and
  a directory copied onto a non-existent path makes that path the new root
  (`:upload ./foo /srv/bar` → `/srv/bar/…`);
- copying a directory onto an existing file is refused.

Before transferring, each command prints the resolved destination, the chosen
mode, and the exact target path of each file (tagged `new` / `overwrite` /
`resume`), then asks for confirmation.

### Drive mounts (`:drive`)

`:drive` manages **OmnyDrive mounts** without leaving the session. It is the
in-session counterpart of the top-level `omnyshell drive` command: because the
session is already attached to one node, the node is **implicit** — paths take no
`<node>:` prefix and every operation is scoped to the connected node.

```text
:drive ls                                            # list this node's mounts
:drive mount <local-dir> <remote-path> [--rw] [--no-initial-sync] [--name N]
:drive mount --git <url> <remote-path> [--rw] [--branch B] [--depth N] [--name N]
:drive status  <mount-id>
:drive sync    <mount-id> [--push|--pull]
:drive resolve <mount-id> [--accept-local|--accept-origin|--reclone]
:drive remount <mount-id>
:drive unmount <mount-id> [--sync-first] [--no-keep-remote]
:drive watch   <mount-id> [--interval S] [--debounce MS]   # background auto-sync
:drive unwatch [<mount-id>]                                # stop watcher(s)
```

`:drive watch` runs **in the background** so the shell stays usable; it logs each
sync above the prompt and is stopped with `:drive unwatch` (all teardown also
happens automatically when the session ends). A mount-id belonging to a different
node is refused. Mounts are shared with the `omnyshell drive` CLI (same on-disk
registry), so a mount created in-session is visible to the CLI and vice versa.

### TCP tunnels (`:tunnel`)

`:tunnel` forwards a TCP port through a public Hub port without leaving the
session — the in-session counterpart of `omnyshell tunnel`, scoped to the
connected node (no `<node>:` prefix needed):

```text
:tunnel <port> [--public-port N]   # expose this node's localhost:<port> on the Hub
:tunnel ls                         # list your active tunnels on this node
:tunnel close <id>                 # close a tunnel by id or prefix
```

Tunnels opened in-session are the same ones `omnyshell tunnel list` reports, and
survive after you detach or exit until explicitly closed.

## Detachable sessions

Leave a node without killing the remote shell, and reconnect later — like
`tmux`/`screen`, but managed by the node. Inside an interactive session,
`:detach` parks it: the PTY, shell and every child process keep running, and you
get a short id to resume with.

```text
:detach            # detach, keep the shell running indefinitely
:detach 30m        # detach with an expiry (units s, m, h, d)
:detach 2h
:detach 1d
```

Manage sessions from the CLI (only your own are ever visible):

```sh
omnyshell sessions list   worker-prod-01            # ID / STATUS / AGE / EXPIRES / COMMAND / PATH
omnyshell sessions peek    worker-prod-01 7ff2caa1   # show its current screen, no attach
omnyshell sessions resume worker-prod-01 7ff2caa1   # full id, short id, or prefix
omnyshell sessions kill   worker-prod-01 7ff2caa1   # running or detached
```

`sessions list` also reports each session's current foreground **command**
(or `-` at the prompt) and working **path**, queried best-effort from the node.

`sessions peek` prints a session's current screen — the same bytes a resume
would repaint — **without attaching** to it or sending any input, so you can
glance at a running or detached session without taking it over. (For a
full-screen program the snapshot carries its alternate-screen frame.)

`sessions kill` works on a **running** session too, not just detached ones — so
you can terminate a stuck session from another window; its attached client is
disconnected.

`sessions list` shows your **active** (attached) sessions as well as detached
ones, so you can detach a session that's busy with a full-screen program from
another terminal — where typing `:detach` is impossible:

```sh
omnyshell sessions detach worker-prod-01            # detach your sole active session
omnyshell sessions detach worker-prod-01 7ff2caa1   # …or name it; optional timeout
```

The attached window drops out of the full-screen app with its terminal restored
and prints a resume hint, while the remote program keeps running.

A resumed shell continues exactly where it left off; output produced while
detached is replayed from a ring buffer. **Full-screen programs are restored
too** — resuming into `nano`, `vim`, `htop` or `less` repaints the screen the
program had drawn before you detached (the node keeps a continuous,
alternate-screen-aware capture), and you reattach straight into the program.
A **dropped connection auto-detaches**
by default (network loss, crash, closed terminal), so an interrupted session is
preserved and resumable rather than lost; a deliberate `:exit` still terminates
the shell.

Detached sessions belong to exactly one authenticated user on one node, and
ownership is enforced by the node — you can never see, resume or kill another
user's session. They live **only in node memory**: nothing is written to disk,
and they are intentionally lost if the node process restarts. The Hub only
authenticates, routes and relays — it never stores detached-session metadata.
The same backend powers the Dart APIs (`RemoteSession.detach`,
`ClientRuntime.resumeSession` / `listDetachedSessions` / `killDetachedSession`)
and the CLI.

## How it works

### Connection flow

1. A **node** dials the Hub over `wss`, authenticates, registers its identity
   and platform, advertises capabilities, then heartbeats.
2. A **client** authenticates, requests a node by identity, and the Hub
   validates permissions and brokers a session.
3. The Hub relays the session over the node's persistent connection (the
   NAT-friendly default), rewriting channel ids between the two ends.

### Security envelope

On top of TLS, the protocol adds replay-resistant login (per-connection nonce +
Ed25519 signature), monotonic heartbeat sequence numbers, per-session authority
bound to the authenticated connection, and Clock-driven keepalive timeouts.
The Hub never ships an allow-all authenticator in its default composition.

See [doc/protocol.md](doc/protocol.md) and [doc/security.md](doc/security.md)
for details.

## Roadmap

The `1.0.0` release ships the secure core, the full Client → Hub → Node vertical
slice, a real `script(1)` PTY shell backend, file transfer (`:download` /
`:upload`, with on-node compression), and a full-featured interactive line
editor. Planned next: deeper authorization (groups, persisted key/token stores,
known-hosts TOFU), the direct-resolution connection strategy, session recording,
richer metrics/tracing, and
promoting the live-resize native PTY backend back to default once its upstream
crash is fixed. The architecture supports these from the start.

## Running the example and tests

```sh
dart pub get
dart analyze
dart test
```

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
