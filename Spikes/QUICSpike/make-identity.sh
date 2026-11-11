#!/bin/sh
# Creates a self-signed localhost certificate and a PKCS#12 bundle for the QUIC spike.
# Output goes to ./identity (gitignored). Never commit the key.
set -eu
cd "$(dirname "$0")"
OUT=identity
PASS="${QUIC_SPIKE_P12_PASSWORD:-spike}"
OPENSSL="${OPENSSL:-openssl}"
mkdir -p "$OUT"
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 30 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "keyUsage=digitalSignature"
# SecPKCS12Import does not reliably accept the OpenSSL 3+ default PKCS#12 encryption
# (AES-256-CBC + PBKDF2), so request the legacy-compatible algorithms explicitly.
"$OPENSSL" pkcs12 -export -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
  -name "quic-spike" -out "$OUT/identity.p12" -passout "pass:$PASS" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
"$OPENSSL" x509 -in "$OUT/cert.pem" -outform der -out "$OUT/cert.der"
echo "Wrote $OUT/identity.p12 (password: $PASS), $OUT/cert.pem, $OUT/cert.der"
