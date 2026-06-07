# omnyshell

[![pub package](https://img.shields.io/pub/v/omnyshell.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/omnyshell)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/OmnyGrid/omnyshell/actions/workflows/dart.yml/badge.svg?branch=main)](https://github.com/OmnyGrid/omnyshell/actions/workflows/dart.yml)
[![License](https://img.shields.io/github/license/OmnyGrid/omnyshell?logo=open-source-initiative&logoColor=green)](https://github.com/OmnyGrid/omnyshell/blob/main/LICENSE)

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
- **Role-based authorization.** The Hub authorizes every session open; the
  bundled `RoleBasedAuthorizer` fails closed.
- **NAT-friendly tunnels.** Nodes dial the Hub outbound and hold a persistent
  connection; the Hub multiplexes sessions over it and relays bytes.
- **Real-time interactive shells & exec.** Streaming stdin/stdout/stderr, exit
  code propagation, terminal resize and interrupt signals, plus an extensible
  local `/command` system.
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
  omnyshell: ^0.1.0
```

OmnyShell uses `dart:io` for TLS, sockets and process execution, so it runs on
any non-web Dart target. A TLS server certificate is required to run a Hub.

## Usage

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

### Connect, exec and discover

```sh
omnyshell connect worker-prod-01 --hub wss://hub.example.com:8443 \
  --principal alice --token "$TOKEN" --ca server.crt

omnyshell exec worker-prod-01 "uname -a" --hub ... --principal alice --token ...

omnyshell nodes list --hub ... --principal alice --token ...
omnyshell whoami    --hub ... --principal alice --token ...
```

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

## Local commands

Inside an interactive session, lines beginning with `/` are **local** OmnyShell
commands and are never sent to the remote shell:

```text
/help  /info  /node  /host  /os  /arch  /session  /capabilities
/latency  /ping  /whoami  /exit
```

The local-command system is extensible — third-party packages can register
custom `LocalCommand`s with a `LocalCommandRegistry`.

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

Stage 1 (this release) ships the secure core and a working Client → Hub → Node
vertical slice. Planned: deeper authorization (groups, persisted key/token
stores, known-hosts TOFU), the direct-resolution connection strategy and generic
TCP tunnels, session recovery and recording, richer metrics/tracing, file
transfer and port forwarding, and a real PTY shell backend. The architecture
supports these from the start.

## Running the example and tests

```sh
dart pub get
dart analyze
dart test
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
