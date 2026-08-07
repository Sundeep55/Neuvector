#!/usr/bin/env bash
# ==============================================================================
# seal.sh — produce SealedSecret encryptedData blobs for dcs-neuvector.
#
# Every blob is bound to ONE cluster's sealed-secrets key pair, so run this
# against each target cluster (or against its fetched public cert) and paste the
# output into that cluster's app-of-apps values file.
#
# Nothing here ever writes plaintext to the repo: temp files live in a mktemp
# dir that is wiped on exit.
#
# Requires: kubeseal, oc/kubectl (or --cert with a fetched pem), yq is not used.
#
# Usage:
#   ./seal.sh pullsecret   <dockerconfig.json>
#   ./seal.sh externaltls  <tls.crt> <tls.key>
#   ./seal.sh bootstrap    <password>
#   ./seal.sh fedinit-primary <clusterName> <fedMasterHost> <port> <joinToken>
#   ./seal.sh fedinit-remote  <clusterName> <fedMasterHost> <port> <joinToken> \
#                             [<fedManagedHost> <port>]
#
# Environment:
#   NS         namespace           (default: dcs-neuvector)
#   CERT       kubeseal --cert pem (optional; otherwise talks to the cluster)
#   CONTROLLER_NS  sealed-secrets controller namespace (default: sealed-secrets)
#   CONTROLLER_NAME sealed-secrets controller name     (default: sealed-secrets)
# ==============================================================================
set -euo pipefail

NS="${NS:-dcs-neuvector}"
CONTROLLER_NS="${CONTROLLER_NS:-sealed-secrets}"
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "error: $*" >&2; exit 1; }
command -v kubeseal >/dev/null || die "kubeseal not found in PATH"

# seal <secret-name> <type> <key=file> [<key=file> ...]
# Builds a plaintext Secret in the temp dir, seals it, and prints only the
# encryptedData block ready to paste under dcs.secrets.<x>.encryptedData.
seal() {
  local name="$1" type="$2"; shift 2
  local args=()
  for kv in "$@"; do
    args+=( "--from-file=${kv}" )
  done

  kubectl create secret generic "$name" \
    --namespace "$NS" --type="$type" --dry-run=client -o yaml "${args[@]}" \
    > "$TMP/secret.yaml"

  local sealargs=( --format yaml --scope strict )
  if [[ -n "${CERT:-}" ]]; then
    sealargs+=( --cert "$CERT" )
  else
    sealargs+=( --controller-namespace "$CONTROLLER_NS" --controller-name "$CONTROLLER_NAME" )
  fi

  echo "# --- paste under the matching dcs.secrets.*.encryptedData ---"
  kubeseal "${sealargs[@]}" < "$TMP/secret.yaml" \
    | awk '/^  encryptedData:/{f=1;next} /^  template:/{f=0} f'
  echo
}

cmd="${1:-}"; shift || true

case "$cmd" in

  pullsecret)
    [[ $# -eq 1 ]] || die "usage: seal.sh pullsecret <dockerconfig.json>"
    cp "$1" "$TMP/.dockerconfigjson"
    seal dcs-neuvector-registry kubernetes.io/dockerconfigjson \
      ".dockerconfigjson=$TMP/.dockerconfigjson"
    ;;

  externaltls)
    [[ $# -eq 2 ]] || die "usage: seal.sh externaltls <tls.crt> <tls.key>"
    # tls.crt must be leaf + intermediates, in that order. The pods serve this
    # directly (passthrough Routes), so a missing chain shows up as a browser
    # trust error, not a NeuVector error. One cert covers UI + API + fed.
    cp "$1" "$TMP/tls.crt"; cp "$2" "$TMP/tls.key"
    seal dcs-neuvector-external-certs kubernetes.io/tls \
      "tls.crt=$TMP/tls.crt" "tls.key=$TMP/tls.key"
    ;;

  bootstrap)
    [[ $# -eq 1 ]] || die "usage: seal.sh bootstrap <password>"
    printf '%s' "$1" > "$TMP/bootstrapPassword"
    seal neuvector-bootstrap-secret Opaque \
      "bootstrapPassword=$TMP/bootstrapPassword"
    ;;

  fedinit-primary)
    [[ $# -eq 4 ]] || die "usage: seal.sh fedinit-primary <clusterName> <fedMasterHost> <port> <joinToken>"
    cat > "$TMP/fedinitcfg.yaml" <<EOF
# Federation PRIMARY. Applied by the controller at startup (NeuVector 5.4.0+).
Cluster_Name: $1
Join_Token: $4
Primary_Rest_Info:
  Server: $2
  Port: $3
# Sync federated registry scan results down to the managed clusters.
Deploy_Repo_Scan_Data: true
EOF
    seal neuvector-init Opaque "fedinitcfg.yaml=$TMP/fedinitcfg.yaml"
    ;;

  fedinit-remote)
    [[ $# -eq 4 || $# -eq 6 ]] || die "usage: seal.sh fedinit-remote <clusterName> <fedMasterHost> <port> <joinToken> [<fedManagedHost> <port>]"
    {
      echo "# Federation REMOTE. Auto-joins the primary at startup."
      echo "Cluster_Name: $1"
      echo "Join_Token: $4"
      echo "Primary_Rest_Info:"
      echo "  Server: $2"
      echo "  Port: $3"
      if [[ $# -eq 6 ]]; then
        echo "Managed_Rest_Info:"
        echo "  Server: $5"
        echo "  Port: $6"
      fi
    } > "$TMP/fedinitcfg.yaml"
    seal neuvector-init Opaque "fedinitcfg.yaml=$TMP/fedinitcfg.yaml"
    ;;

  jointoken)
    # Convenience: the join token must be a UUID, identical on primary+remotes.
    if command -v uuidgen >/dev/null; then uuidgen | tr 'A-Z' 'a-z'
    else python3 -c 'import uuid;print(uuid.uuid4())'; fi
    ;;

  *)
    sed -n '2,30p' "$0"
    exit 1
    ;;
esac
