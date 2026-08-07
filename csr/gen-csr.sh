#!/usr/bin/env bash
# ==============================================================================
# gen-csr.sh — generate the 4096-bit key + CSR for one NeuVector UI hostname.
#
#   ./gen-csr.sh neuvector-dev.conf
#   ./gen-csr.sh                      # all *.conf in this directory
#
# Output goes to ./out/ (git-ignored — private keys must never be committed).
# Hand the .csr to the CA team; when the signed cert returns, build tls.crt as
# leaf-first followed by any intermediates, then seal it:
#
#   cat out/neuvector-dev.csr                      # -> submit this
#   cat signed.crt intermediate.crt > out/tls.crt  # chain order matters
#   ../dcs-neuvector/scripts/seal.sh externaltls out/tls.crt out/neuvector-dev.key
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p out
chmod 700 out

gen() {
  local conf="$1"
  local base="${conf%.conf}"
  local cn
  cn="$(awk -F'=' '/^CN[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$conf")"

  echo "==> $base  (CN=$cn)"
  openssl req -new -newkey rsa:4096 -nodes \
    -keyout "out/${base}.key" \
    -out    "out/${base}.csr" \
    -config "$conf"
  chmod 600 "out/${base}.key"

  echo "--- SAN check ---"
  openssl req -in "out/${base}.csr" -noout -text \
    | grep -A1 'Subject Alternative Name'
  echo
}

if [[ $# -gt 0 ]]; then
  for c in "$@"; do gen "$c"; done
else
  for c in *.conf; do gen "$c"; done
fi

echo "Keys and CSRs are in $(pwd)/out — do not commit out/."
