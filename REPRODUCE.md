# Reproducing the `portable_pty` SIGCHLD crash with OmnyShell

This branch (`repro/portable-pty-sigchld-crash`) exists **only** to reproduce a
memory-safety crash in the [`portable_pty`](https://pub.dev/packages/portable_pty)
native library so its maintainer can investigate. It is not meant to be merged
or published.

## The bug

`portable_pty`'s native side installs a process-global `SIGCHLD` handler. That
handler races the Dart VM's own child reaper. When OmnyShell opens and closes
interactive PTY sessions in quick succession, the process intermittently
segfaults — typically `EXC_BAD_ACCESS` on macOS (sometimes surfaced as
"Code Signature Invalid") inside / around `portable_pty_open`.

It is a race, so it does **not** reproduce reliably in a tiny standalone
program; it shows up under the session churn of the real application. Hence this
repro harness.

Upstream issue tracker: https://github.com/kingwill101/dart_terminal/issues

## What this branch changes vs `master`

- `pubspec.yaml`: re-enables `portable_pty: ^0.0.5`.
- `lib/src/infrastructure/backend/pty/pty_shell_backend.dart` &
  `pty_shell_session.dart`: the FFI backend/session, un-parked from `.txt`
  (they were archived on `master` precisely because of this crash).
- `bin/omnyshell.dart`: the `node start --pty-backend native` path is wired back
  in **and made the default**, so a normal `node start` uses `portable_pty`.

`--pty-backend script` (the `master` default) and `--pty-backend none` remain
available and do **not** crash — useful to confirm the fault lives in the native
library, not in OmnyShell.

## Prerequisites

- Dart SDK `^3.10.9`.
- macOS or Linux (the FFI backend self-disables on Windows and falls back to a
  pipe shell).
- Three terminals.

```sh
dart pub get
```

## Reproduction

OmnyShell speaks only WebSocket-on-TLS, so a Hub, a Node and a Client are
involved. The Node is the process that loads `portable_pty` and crashes.

### Terminal 1 — Hub

```sh
./run-hub.sh
```

Generates throwaway dev certificates on first run and starts a Hub on
`wss://127.0.0.1:8443` with two grants: `alice:s3cr3t:admin` (client) and
`noded:nodetok:node` (node).

### Terminal 2 — Node (the process under test)

`node start` defaults to `--pty-backend native` on this branch, so this loads
`portable_pty`:

```sh
dart run bin/omnyshell.dart node start \
  --hub wss://127.0.0.1:8443 --ca certs/ca.crt \
  --token nodetok --id worker-01
```

### Terminal 3 — Client: churn interactive sessions

Each `connect` opens an interactive PTY session on the node; exiting it closes
the PTY and reaps the child — that open/close cycle is what races the SIGCHLD
handler. Repeat it in a loop until the **Node process in Terminal 2** crashes:

```sh
for i in $(seq 1 200); do
  echo "exit" | dart run bin/omnyshell.dart connect worker-01 \
    --hub wss://127.0.0.1:8443 --ca certs/ca.crt --token s3cr3t
done
```

(You can also connect interactively and repeatedly run short commands / open and
exit shells; the loop above just automates the churn.)

### Expected result

The **Node** process (Terminal 2) crashes intermittently with a native fault —
`EXC_BAD_ACCESS` / SIGSEGV (and on macOS sometimes "Code Signature Invalid") —
in or around `portable_pty_open`. On macOS a crash report is written to
`~/Library/Logs/DiagnosticReports/`. Rerun the loop a few times if it survives
the first pass; it is timing-dependent.

## Confirming the fault is in `portable_pty`

Restart the Node with the non-native backend and run the same client loop — it
does not crash:

```sh
dart run bin/omnyshell.dart node start \
  --hub wss://127.0.0.1:8443 --ca certs/ca.crt \
  --token nodetok --id worker-01 \
  --pty-backend script
```

`script` uses the system `script(1)` utility (an ordinary child process, no
FFI), so the node only does pipe I/O and reaps a normal child — there is no
process-global native SIGCHLD handler to race.
