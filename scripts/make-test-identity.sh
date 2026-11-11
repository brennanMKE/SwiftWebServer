#!/bin/sh
# Creates the local test identity (#0072): a self-signed certificate for localhost,
# 127.0.0.1 and ::1, and a PKCS#12 bundle with a fixed test password, in the gitignored
# .test-identity/ folder at the repository root. Adapted from Spikes/QUICSpike/make-identity.sh.
#
#   scripts/make-test-identity.sh           # creates the identity if it is missing (idempotent)
#   scripts/make-test-identity.sh --force   # replaces it
#
# Output:
#   .test-identity/server.p12   PKCS#12 identity, password "sws-test-password"
#   .test-identity/cert.pem     certificate (PEM)
#   .test-identity/cert.der     certificate (DER, for pinning in test clients)
#   .test-identity/key.pem      private key (PEM, unencrypted)
#
# This script only runs openssl on files. It never touches the keychain or trust settings
# (AGENTS.md). Code loads the identity in memory with SecPKCS12Import and
# kSecImportToMemoryOnly. Trusting a local CA for browser checks is a manual owner step;
# see issues/0072.md.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/.test-identity"
PASSWORD="sws-test-password"

if [ -z "${OPENSSL:-}" ]; then
  # /usr/bin/openssl is LibreSSL; prefer Homebrew OpenSSL when it is installed.
  if [ -x /opt/homebrew/bin/openssl ]; then OPENSSL=/opt/homebrew/bin/openssl; else OPENSSL=openssl; fi
fi

if [ "${1:-}" != "--force" ] && [ -s "$OUT/server.p12" ] && [ -s "$OUT/cert.der" ] && [ -s "$OUT/key.pem" ]; then
  echo "Test identity already exists: $OUT/server.p12"
  exit 0
fi

# Build in a private temporary folder next to the output, then move the files into place, so
# that concurrent test processes never see a half-written identity.
mkdir -p "$OUT"
TMP=$(mktemp -d "$OUT/.tmp.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 825 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "keyUsage=critical,digitalSignature" 2>/dev/null
# SecPKCS12Import does not reliably accept the OpenSSL 3+ default PKCS#12 encryption
# (AES-256-CBC + PBKDF2), so request the legacy-compatible algorithms explicitly.
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "sws-test-identity" -out "$TMP/server.p12" -passout "pass:$PASSWORD" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
"$OPENSSL" x509 -in "$TMP/cert.pem" -outform der -out "$TMP/cert.der"
chmod 600 "$TMP/key.pem" "$TMP/server.p12"

# server.p12 is moved last: its presence marks a complete identity.
for f in key.pem cert.pem cert.der server.p12; do mv -f "$TMP/$f" "$OUT/$f"; done
echo "Wrote $OUT/server.p12 (password: $PASSWORD), cert.pem, cert.der, key.pem"
