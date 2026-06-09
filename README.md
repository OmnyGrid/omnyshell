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

## API Documentation

See the [API Documentation][api_doc] for the full list of classes and APIs.

[api_doc]: https://pub.dev/documentation/omnyshell/latest/

## Features

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
> use a certificate from a real CA. There is no insecure/skip-verify mode.

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

### Connect, exec and discover

After `login`, run any client command with no credential flags:

```sh
omnyshell connect worker-prod-01
omnyshell exec worker-prod-01 "uname -a"
omnyshell nodes list
omnyshell whoami
```

Or pass credentials explicitly (and target another Hub) on any single command:

```sh
omnyshell connect worker-prod-01 --hub wss://hub.example.com:8443 \
  --principal alice --token "$TOKEN" --ca server.crt
```

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

## Local commands

Inside an interactive session, lines beginning with `:` are **local** OmnyShell
commands and are never sent to the remote shell:

```text
:help  :info  :node  :host  :os  :arch  :session  :capabilities
:latency  :ping [count]  :whoami  :download  :upload  :exit
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
known-hosts TOFU), the direct-resolution connection strategy and generic TCP
tunnels / port forwarding, session recovery and recording, richer
metrics/tracing, and promoting the live-resize native PTY backend back to
default once its upstream crash is fixed. The architecture supports these from
the start.

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
