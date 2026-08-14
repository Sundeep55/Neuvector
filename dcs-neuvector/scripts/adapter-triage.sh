#!/usr/bin/env bash
# ==============================================================================
# adapter-triage.sh — collect everything needed to diagnose a NeuVector registry
# adapter / Harbor scanner failure, in one run.
#
# READ-ONLY. It creates nothing, changes nothing, and redacts secret values
# (only SHA-256 prefixes are printed, so credentials can be *compared* across
# the two sides without ever being pasted anywhere).
#
# Usage:
#   export HARBOR_NS=harbor
#   export HARBOR_URL=https://registry.x.com
#   export HARBOR_ADMIN=admin
#   read -rs HARBOR_PASS && export HARBOR_PASS        # not echoed, not in history
#   export SCANNER_NAME=neuvector-qa
#   export TEST_IMAGE=myproject/myapp:1.2.3           # the artifact that failed
#   ./adapter-triage.sh > triage-$(date +%Y%m%d-%H%M).txt 2>&1
#
# Optional:
#   NV_NS           NeuVector namespace           (default: dcs-neuvector)
#   KUBECTL         kubectl or oc                 (default: oc)
# ==============================================================================
set -uo pipefail

NV_NS="${NV_NS:-dcs-neuvector}"
HARBOR_NS="${HARBOR_NS:?set HARBOR_NS}"
HARBOR_URL="${HARBOR_URL:?set HARBOR_URL}"
HARBOR_ADMIN="${HARBOR_ADMIN:-admin}"
HARBOR_PASS="${HARBOR_PASS:?set HARBOR_PASS}"
SCANNER_NAME="${SCANNER_NAME:?set SCANNER_NAME}"
TEST_IMAGE="${TEST_IMAGE:-}"
K="${KUBECTL:-oc}"

hash12() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-12 || \
           printf '%s' "$1" | sha256sum | cut -c1-12; }
sec() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
sub() { echo; echo "--- $* ---"; }

sec "0. CONTEXT"
date -u
$K version -o json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print("server:",d.get("serverVersion",{}).get("gitVersion"))' 2>/dev/null
echo "NV_NS=$NV_NS  HARBOR_NS=$HARBOR_NS  SCANNER_NAME=$SCANNER_NAME"

# ------------------------------------------------------------------------------
sec "1. NEUVECTOR SIDE — pods and readiness"
# The adapter blocks before it listens until it can read the scanner version from
# the controller, so controller/scanner readiness is a precondition, not detail.
$K -n "$NV_NS" get pods -o wide
sub "restart counts and age (did the adapter restart after the cert/CA change?)"
$K -n "$NV_NS" get pods -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,START:.status.startTime

# ------------------------------------------------------------------------------
sec "2. ADAPTER — deployment wiring"
$K -n "$NV_NS" get deploy neuvector-registry-adapter-pod -o yaml 2>/dev/null \
  | grep -E "image:|name: HARBOR_|name: CLUSTER_JOIN_ADDR|secretName:|mountPath:|subPath:|containerPort" || echo "adapter deployment not found"
sub "service"
$K -n "$NV_NS" get svc neuvector-service-registry-adapter -o yaml 2>/dev/null \
  | grep -E "name:|port:|targetPort:|type:|appProtocol"
sub "route (if any)"
$K -n "$NV_NS" get route -o custom-columns=NAME:.metadata.name,HOST:.spec.host,PORT:.spec.port.targetPort,TLS:.spec.tls.termination 2>/dev/null

sub "adapter logs (full — the first lines matter most)"
$K -n "$NV_NS" logs deploy/neuvector-registry-adapter-pod --tail=200 2>/dev/null \
  || echo "no adapter logs"
# Expect: 'START - version=...' followed by activity. START and then silence means
# it is still blocked in `for nvScanner.Version == ""` and is NOT listening.

# ------------------------------------------------------------------------------
sec "3. ADAPTER — the certificate it actually serves"
ADAPTER_CERT_SECRET=$($K -n "$NV_NS" get deploy neuvector-registry-adapter-pod \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="cert")].secret.secretName}' 2>/dev/null)
echo "cert secret in use: ${ADAPTER_CERT_SECRET:-<none - adapter self-generated its own>}"
if [[ -n "${ADAPTER_CERT_SECRET:-}" ]]; then
  $K -n "$NV_NS" get secret "$ADAPTER_CERT_SECRET" -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
fi
sub "internal CA (what Harbor must trust, if using the in-cluster cert)"
$K -n "$NV_NS" get secret dcs-neuvector-internal-certs -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256 2>/dev/null \
  || echo "no internal CA secret"
sub "cert-manager Certificate objects (renewal timing)"
$K -n "$NV_NS" get certificate -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status,NOTAFTER:.status.notAfter,RENEWAL:.status.renewalTime 2>/dev/null

# ------------------------------------------------------------------------------
sec "4. ADAPTER CREDENTIAL — fingerprints only, never the value"
# Compare these two numbers with the ones Harbor holds (section 6). If they
# differ, that alone explains an auth failure.
AU=$($K -n "$NV_NS" get secret dcs-neuvector-adapter-auth -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
AP=$($K -n "$NV_NS" get secret dcs-neuvector-adapter-auth -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [[ -n "${AU:-}" ]]; then
  echo "adapter secret username sha256[0:12] = $(hash12 "$AU")   (length ${#AU})"
  echo "adapter secret password sha256[0:12] = $(hash12 "$AP")   (length ${#AP})"
else
  echo "dcs-neuvector-adapter-auth not found or has no username/password keys"
fi

# ------------------------------------------------------------------------------
sec "5. NEUVECTOR CONTROLLER / SCANNER"
$K -n "$NV_NS" get deploy -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas
sub "controller log — declarative config applied?"
$K -n "$NV_NS" logs deploy/neuvector-controller-pod --tail=100 2>/dev/null | grep -iE "initcfg|cacert|tls" | tail -20

# ------------------------------------------------------------------------------
sec "6. HARBOR — scanner registration as Harbor stores it"
curl -sS -u "$HARBOR_ADMIN:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/scanners" \
  | python3 -c '
import sys, json
try: rows = json.load(sys.stdin)
except Exception as e: print("could not parse:", e); sys.exit()
for r in rows:
    print(json.dumps({k: r.get(k) for k in
        ("uuid","name","url","auth","disabled","is_default","health",
         "skip_certVerify","skip_cert_verify","use_internal_addr",
         "adapter","vendor","version")}, indent=2))
'
UUID=$(curl -sS -u "$HARBOR_ADMIN:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/scanners" \
  | python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if r.get('name')=='$SCANNER_NAME': print(r['uuid'])
" 2>/dev/null)
echo "registration uuid for $SCANNER_NAME: ${UUID:-NOT FOUND}"

sub "6b. THE DECISIVE CALL — Harbor's own metadata ping (same call the scan makes)"
if [[ -n "${UUID:-}" ]]; then
  curl -sS -w '\nHTTP %{http_code}\n' -u "$HARBOR_ADMIN:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/scanners/$UUID/metadata"
fi
# Healthy output contains consumes_mime_types including
#   application/vnd.oci.image.manifest.v1+json
# Anything else here IS the root cause of the "does not support mime type" error.

# ------------------------------------------------------------------------------
sec "7. HARBOR CORE — replicas, proxy, trust store"
$K -n "$HARBOR_NS" get pods -l component=core -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,START:.status.startTime
echo "^^ if there is more than one, were ALL restarted after the CA bundle change?"
CORE=$($K -n "$HARBOR_NS" get pods -l component=core -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "using core pod: ${CORE:-none}"

sub "proxy env (a set HTTPS_PROXY with the adapter host not in NO_PROXY -> 'Forbidden')"
$K -n "$HARBOR_NS" set env deploy/harbor-core --list 2>/dev/null | grep -iE "proxy" || echo "no proxy env"

if [[ -n "${CORE:-}" ]]; then
  sub "custom CA material mounted into core"
  $K -n "$HARBOR_NS" exec "$CORE" -- sh -c 'ls -la /harbor_cust_cert/ 2>/dev/null || echo "no /harbor_cust_cert"'
  sub "is the adapter CA present in core's trust store?"
  $K -n "$HARBOR_NS" exec "$CORE" -- sh -c \
    'for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
       [ -f "$f" ] && echo "$f: $(grep -c "BEGIN CERTIFICATE" "$f") certs, mtime $(date -r "$f" 2>/dev/null)"; done'
fi

# ------------------------------------------------------------------------------
sec "8. PROBE THE ADAPTER FROM INSIDE HARBOR-CORE (the only test that counts)"
# Same pod, same network path, same trust store Harbor uses.
ENDPOINT=$(curl -sS -u "$HARBOR_ADMIN:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/scanners" \
  | python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if r.get('name')=='$SCANNER_NAME': print(r['url'])
" 2>/dev/null)
echo "registered endpoint: ${ENDPOINT:-NOT FOUND}"
if [[ -n "${CORE:-}" && -n "${ENDPOINT:-}" ]]; then
  sub "8a. with TLS verification (expect 200 + JSON if trust is correct)"
  $K -n "$HARBOR_NS" exec "$CORE" -- sh -c \
    "curl -sS -o /dev/null -w 'HTTP %{http_code}  tls_verify=OK\n' '${ENDPOINT}/api/v1/metadata' 2>&1 | head -3" \
    || echo "curl not present in core image — note this and skip 8a/8b"
  sub "8b. ignoring TLS (isolates trust from reachability/auth)"
  $K -n "$HARBOR_NS" exec "$CORE" -- sh -c \
    "curl -sSk -o /dev/null -w 'HTTP %{http_code}\n' '${ENDPOINT}/api/v1/metadata' 2>&1 | head -3"
  sub "8c. ignoring TLS, with credentials (expect 200 + JSON)"
  echo "run manually so the password never enters a log:"
  echo "  $K -n $HARBOR_NS exec -it $CORE -- curl -sSk -u '<user>:<pass>' '${ENDPOINT}/api/v1/metadata'"
fi

# ------------------------------------------------------------------------------
sec "9. THE ARTIFACT THAT FAILED"
if [[ -n "$TEST_IMAGE" ]]; then
  PROJ="${TEST_IMAGE%%/*}"; REST="${TEST_IMAGE#*/}"
  REPO="${REST%%:*}"; REF="${REST##*:}"
  echo "project=$PROJ repo=$REPO ref=$REF"
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(urllib.parse.quote('$REPO',safe=''),safe=''))")
  curl -sS -u "$HARBOR_ADMIN:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/projects/$PROJ/repositories/$ENC/artifacts/$REF?with_scan_overview=true&with_accessory=true" \
    | python3 -c '
import sys, json
a = json.load(sys.stdin)
if isinstance(a, dict) and a.get("errors"): print(json.dumps(a)); sys.exit()
print(json.dumps({
  "type": a.get("type"),
  "media_type": a.get("media_type"),
  "manifest_media_type": a.get("manifest_media_type"),
  "digest": a.get("digest"),
  "is_index": bool(a.get("references")),
  "accessories": [x.get("type") for x in (a.get("accessories") or [])],
  "scan_overview_keys": list((a.get("scan_overview") or {}).keys()),
}, indent=2))
'
  # type must be IMAGE and manifest_media_type must appear in the adapter
  # capabilities from 6b. If type is not IMAGE, no scanner can scan it.
else
  echo "TEST_IMAGE not set — skipped"
fi

# ------------------------------------------------------------------------------
sec "10. HARBOR CORE LOGS — the real error, which hides under a different prefix"
$K -n "$HARBOR_NS" logs deploy/harbor-core --tail=4000 2>/dev/null \
  | grep -E "api controller: get project scanner|scanner controller: ping|does not support scanning artifact|registry-adapter" \
  | tail -40
echo
echo "The 'api controller: get project scanner' lines are the actual failure."
echo "The 'does not support scanning artifact' line is only its symptom."

sec "END — attach this whole file"
