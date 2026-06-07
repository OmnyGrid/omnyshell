#!/usr/bin/env bash
#
# Generate development TLS certificates for running an OmnyShell Hub locally.
#
# OmnyShell is secure-by-default: the Hub only speaks WebSocket-on-TLS (wss),
# so `omnyshell hub start` requires a server certificate and private key. This
# script creates a small local Certificate Authority (CA) and a server
# certificate signed by it, written to ./certs:
#
#   certs/ca.crt      - the CA certificate (clients/nodes trust this: --ca)
#   certs/ca.key      - the CA private key (keep local; never deploy)
#   certs/server.crt  - the Hub server certificate (hub start: --cert)
#   certs/server.key  - the Hub server private key (hub start: --key)
#
# A CA -> leaf chain is used (rather than a bare self-signed certificate) because
# a self-signed *leaf* used as its own trust anchor is rejected by Dart's TLS
# stack when a client later verifies it. The CA carries keyCertSign and the leaf
# carries the serverAuth extended key usage (both required by Dart/BoringSSL),
# and server.crt is the full chain (leaf + CA) so verification succeeds cleanly.
#
# Usage:
#   tool/gen-dev-certs.sh [host]
#
#   host  Extra hostname to add to the certificate's SAN (default: just
#         localhost + 127.0.0.1). Example: tool/gen-dev-certs.sh hub.local
#
# Re-running is a no-op once certs/server.crt exists; delete the certs/
# directory to regenerate.

set -euo pipefail

CERT_DIR="${CERT_DIR:-certs}"
EXTRA_HOST="${1:-}"

if [[ -f "$CERT_DIR/server.crt" ]]; then
  echo "Certificates already exist in $CERT_DIR/ — nothing to do."
  echo "Delete $CERT_DIR/ to regenerate."
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "error: openssl is required but not found on PATH" >&2
  exit 1
fi

mkdir -p "$CERT_DIR"

# Subject Alternative Names the Hub certificate is valid for.
SAN="DNS:localhost,IP:127.0.0.1"
if [[ -n "$EXTRA_HOST" ]]; then
  SAN="$SAN,DNS:$EXTRA_HOST"
fi

echo "==> Generating local CA"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
  -days 3650 -subj "/CN=OmnyShell Dev CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

echo "==> Generating server key and CSR"
openssl req -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.csr" \
  -subj "/CN=localhost" >/dev/null 2>&1

echo "==> Signing server certificate with the CA (SAN: $SAN)"
openssl x509 -req -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
  -out "$CERT_DIR/server-leaf.crt" -days 825 \
  -extfile <(printf "subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" "$SAN") \
  >/dev/null 2>&1

# The Hub presents the full chain (leaf + CA) so clients can build the path.
cat "$CERT_DIR/server-leaf.crt" "$CERT_DIR/ca.crt" > "$CERT_DIR/server.crt"
rm -f "$CERT_DIR/server.csr" "$CERT_DIR/server-leaf.crt"

echo
echo "Certificates written to $CERT_DIR/:"
echo "  $CERT_DIR/server.crt  (hub start --cert)"
echo "  $CERT_DIR/server.key  (hub start --key)"
echo "  $CERT_DIR/ca.crt      (client/node --ca)"
echo
echo "Start the Hub:"
echo "  dart run bin/omnyshell.dart hub start \\"
echo "    --host 127.0.0.1 --port 8443 \\"
echo "    --cert $CERT_DIR/server.crt --key $CERT_DIR/server.key \\"
echo "    --grant-token \"alice:s3cr3t:admin\""
echo
echo "Connect a client (in another shell):"
echo "  dart run bin/omnyshell.dart exec <node> \"uname -a\" \\"
echo "    --hub wss://127.0.0.1:8443 \\"
echo "    --principal alice --token s3cr3t --ca $CERT_DIR/ca.crt"
