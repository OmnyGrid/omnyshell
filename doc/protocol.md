# OmnyShell Protocol

OmnyShell multiplexes many logical channels (sessions today; tunnels and file
transfer later) over a single WebSocket-on-TLS connection, SSH-channel style.

## Frame types

The transport carries two physical WebSocket frame kinds, distinguished for free
by `web_socket_channel` (text → `String`, binary → `List<int>`):

- **Text frame → control message.** A JSON envelope:

  ```json
  { "t": "<type>", "c": <channelId?>, "d": { ... } }
  ```

  `t` is the type discriminator, `c` is the channel id (omitted for
  connection-level messages), and `d` is the payload.

- **Binary frame → stream data.** A fixed 10-byte big-endian header followed by
  the raw bytes:

  | offset | size | field        |
  | ------ | ---- | ------------ |
  | 0      | 1    | version (`0x01`) |
  | 1      | 1    | opcode (`0x01` stdin, `0x02` stdout, `0x03` stderr) |
  | 2      | 4    | channel id (uint32) |
  | 6      | 4    | payload length (uint32) |
  | 10     | N    | payload bytes |

  Payloads are capped at 64 KiB (`FrameCodec.maxDataPayload`); larger writes are
  split. Stream EOF is an explicit `channel.eof` control message, not a
  zero-length frame, so half-close is unambiguous.

## Channels

A channel id is a `uint32` scoped to one connection; `0` is reserved for
connection-level control. Each side allocates the ids for channels it opens. The
`ChannelMultiplexer` owns the channel table, id allocation and per-hop
pause/resume; per-channel credit windows (`channel.window`, default 256 KiB)
provide end-to-end backpressure.

## Control messages

| Type | Direction | Purpose |
| --- | --- | --- |
| `hello` | both | Handshake; the Hub includes a single-use challenge nonce |
| `auth.request` / `auth.ok` / `auth.fail` | both | Authentication |
| `node.register` / `node.registered` | node ⇄ hub | Register identity & platform |
| `node.capabilities` | node → hub | Advertise capabilities |
| `node.heartbeat` / `node.heartbeat.ack` | node ⇄ hub | Liveness (monotonic `seq`) |
| `ping` / `pong` | both | RTT + half-open detection |
| `node.list.request` / `node.list.response` | client ⇄ hub | Discovery |
| `session.open` / `session.opened` / `session.rejected` | client ⇄ hub | Open a session |
| `node.session.open` / `.opened` / `.rejected` | hub ⇄ node | Node-side session |
| `channel.resize` / `channel.signal` / `channel.eof` | client → node | Session control |
| `channel.exit` / `channel.close` | node → client | Termination |
| `channel.window` | both | Backpressure credit |
| `error` | both | Protocol/connection error |

## Session brokering (tunnel relay)

The default, NAT-friendly strategy:

1. Client sends `session.open` on a new client channel `Cc`.
2. The Hub looks up the node, authorizes the principal, allocates a node-side
   channel `Cn`, records a `SessionRoute` bridging `(client, Cc) ↔ (node, Cn)`,
   and sends `node.session.open` to the node.
3. The node starts a `ShellBackend` session and replies `node.session.opened`;
   the Hub forwards `session.opened` to the client.
4. Data and channel control are relayed by **rewriting the channel id** between
   the two ends — the Hub never parses stream payloads.

A future direct-resolution strategy lets a client connect straight to a node
using a Hub-signed grant, reusing the same codec, channels and session classes.

## Versioning

`hello` carries `protocolVersion`/`minVersion`; incompatible peers are rejected
during the handshake. The current version is `1`.
