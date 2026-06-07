#!/usr/bin/env bash
#
# run-hub.sh — start an OmnyShell Hub for local development.
#
# OmnyShell only speaks WebSocket-on-TLS (wss), so the Hub needs a server
# certificate and key. This script generates throwaway dev certificates (via
# tool/gen-dev-certs.sh) on first run, then starts the Hub.
#
# Usage:
#   ./run-hub.sh
#
# Everything is configured through environment variables (defaults shown). Set
# them inline to override, e.g.:
#   OMNYSHELL_PORT=9443 ./run-hub.sh
#
# Environment variables:
#   OMNYSHELL_HOST          Interface to bind. Default: 127.0.0.1.
#   OMNYSHELL_PORT          TCP port to listen on. Default: 8443.
#   OMNYSHELL_CERT          Server certificate (chain) PEM. Default: certs/server.crt.
#   OMNYSHELL_KEY           Server private key PEM. Default: certs/server.key.
#   OMNYSHELL_GRANT_TOKEN   A token grant "principal:token:roles". May be a
#                           space-separated list of grants. Default:
#                           "alice:s3cr3t:admin noded:nodetok:node".
#
# Connect a client/node to this Hub by trusting the dev CA:
#   --hub wss://127.0.0.1:8443 --ca certs/ca.crt

set -euo pipefail

cd "$(dirname "$0")"

HOST="${OMNYSHELL_HOST:-127.0.0.1}"
PORT="${OMNYSHELL_PORT:-8443}"
CERT="${OMNYSHELL_CERT:-certs/server.crt}"
KEY="${OMNYSHELL_KEY:-certs/server.key}"
GRANTS="${OMNYSHELL_GRANT_TOKEN:-alice:s3cr3t:admin noded:nodetok:node}"

# Generate dev certificates if the configured cert/key are missing.
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
  echo "Certificate or key not found — generating dev certificates..."
  bash tool/gen-dev-certs.sh
fi

dart pub get

# Build the --grant-token arguments from the (possibly multi-value) grant list.
GRANT_ARGS=()
for grant in $GRANTS; do
  GRANT_ARGS+=(--grant-token "$grant")
done

echo "Starting OmnyShell Hub on wss://${HOST}:${PORT}"
echo "  cert: $CERT"
echo "  key:  $KEY"
echo "Connect with: --hub wss://${HOST}:${PORT} --ca certs/ca.crt"
echo

exec dart run bin/omnyshell.dart hub start \
  --host "$HOST" --port "$PORT" \
  --cert "$CERT" --key "$KEY" \
  "${GRANT_ARGS[@]}"
