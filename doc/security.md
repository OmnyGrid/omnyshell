# OmnyShell Security Model

Security is mandatory and fails closed. There is no plaintext or raw-TCP mode.

## Transport

Every connection is WebSocket-on-TLS (`wss`). The Hub binds with a mandatory
`SecurityContext` (certificate chain + private key). Clients and nodes verify the
Hub certificate against their trust roots; a `SecurityContext` with
`setTrustedCertificates` pins a private CA. The `onBadCertificate` hook on the
client/node configs exists for certificate pinning and self-signed test
certificates — it is `null` (standard verification) by default and should stay
that way in production.

## Authentication

Authentication is pluggable via the `Authenticator` contract:

- **`PublicKeyAuthenticator`** — Ed25519, `authorized_keys`-style. The Hub issues
  a fresh single-use nonce in its `hello`; the client/node signs it with its
  private key, and the Hub verifies the signature against the registered public
  key. Because the nonce is per-connection and single-use, a captured signature
  cannot be replayed onto a new connection.
- **`TokenAuthenticator`** — bearer tokens compared in constant time; token
  secrecy in transit is provided by TLS, and the presented principal must match
  the token's grant.
- **`CompositeAuthenticator`** — accept several credential types at once.

The Hub never wires an allow-all authenticator into its default composition
root. Authentication failures close the connection.

## Authorization

The Hub authorizes **every** `session.open` through the `Authorizer` contract.
The bundled `RoleBasedAuthorizer` is fail-closed: admins may reach any node;
everyone else needs a role listed in the node's `allow-roles` label; a node with
no `allow-roles` label is admin-only.

## Session integrity

- **Hijack resistance.** Authority over a session is bound to the authenticated
  physical connection that owns its channel. Session-mutating control
  (`signal`, `resize`, `close`) is only honoured on that connection's channel.
  Each route also carries a 256-bit per-session token (used to bind future
  direct-mode grants).
- **Replay/stall detection.** Node heartbeats carry a strictly increasing
  sequence number; out-of-order or duplicate heartbeats are ignored.
- **Liveness.** A Clock-driven watchdog marks a node offline and tears down its
  routes after it misses heartbeats; WebSocket pings detect half-open
  connections and drive node reconnection.

## Auditing

The Hub records security-relevant events (`auth.ok`, `auth.fail`,
`node.register`, `session.open`, `session.rejected`, `session.close`,
`node.offline`, `node.timeout`) in a bounded in-memory `AuditLog`. Later stages
add pluggable sinks (file, syslog, SIEM).

## Reporting

Please report security issues privately to the maintainers rather than via the
public issue tracker.
