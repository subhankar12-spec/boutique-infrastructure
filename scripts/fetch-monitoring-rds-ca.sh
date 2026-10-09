#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p certs
BUNDLE_TMP=$(mktemp)
trap 'rm -f "$BUNDLE_TMP"' EXIT
curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o "$BUNDLE_TMP"
openssl crl2pkcs7 -nocrl -certfile "$BUNDLE_TMP" | openssl pkcs7 -print_certs -noout >/dev/null
install -m 0644 "$BUNDLE_TMP" certs/rds-global-bundle.pem
sha256sum certs/rds-global-bundle.pem
