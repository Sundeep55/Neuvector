#!/usr/bin/env bash
# ==============================================================================
# adapter-triage.sh — one-shot data collection for a NeuVector registry adapter
# / Harbor pluggable-scanner failure.
#
# Works in both topologies:
#   SAME-CLUSTER  Harbor and NeuVector in one cluster (QA hub, in-cluster svc DNS)
#   CROSS-CLUSTER Harbor in cluster A, NeuVector in cluster B, adapter exposed
#                 as a Route (dev + internet-connected Harbor)
# Set HARBOR_CONTEXT / NV_CONTEXT to pick the kube context for each half. Leave
# both unset (or equal) and it behaves exactly as the same-cluster version.
#
# Sections are tagged [Qn] with the triage question they answer.
#
# READ-ONLY by default. Two opt-in mutations, both clearly announced:
#   SET_PROJECT_SCANNER=1  point the test project at this scanner (and print the
#                          command to restore the previous one)
#   DO_SCAN=1              trigger a scan of TEST_IMAGE to reproduce the failure
#
# Credentials are never printed — only SHA-256 prefixes, so the two sides can be
# compared without the value appearing in the log.
#
# Everything goes to stdout AND to a log file, so you can watch it and still
# hand over one artefact.
#
# ------------------------------------------------------------------------------
# REQUIRED
#   HARBOR_NS         namespace Harbor runs in
#   HARBOR_URL        e.g. https://registry.x.com
#   HARBOR_PASS       admin password (read -rs HARBOR_PASS && export HARBOR_PASS)
#   SCANNER_NAME      the registration name in Harbor, e.g. neuvector-dev
#
# CLUSTER SELECTION
#   HARBOR_CONTEXT    kube context for the Harbor cluster   (default: current)
#   NV_CONTEXT        kube context for the NeuVector cluster(default: current)
#                     `oc config get-contexts` to list them
#
# NAME OVERRIDES (defaults match the dcs-neuvector chart)
#   NV_NS=dcs-neuvector             NV_ADAPTER_DEPLOY=neuvector-registry-adapter-pod
#   NV_ADAPTER_SVC=neuvector-service-registry-adapter
#   NV_CONTROLLER_DEPLOY=neuvector-controller-pod
#   NV_SCANNER_DEPLOY=neuvector-scanner-pod
#   NV_ADAPTER_AUTH_SECRET=dcs-neuvector-adapter-auth
#   NV_INTERNAL_CA_SECRET=dcs-neuvector-internal-certs
#   NV_ADAPTER_CERT_SECRET=<auto-detected from the deployment>
#   HARBOR_CORE_SELECTOR=component=core   HARBOR_JOBSVC_SELECTOR=component=jobservice
#   HARBOR_CORE_DEPLOY=harbor-core        HARBOR_ADMIN=admin
#
# BEHAVIOUR
#   TEST_IMAGE=project/repo:tag   the artifact to inspect — enables [Q9][Q11]
#   PING_COUNT=5                  metadata pings — [Q10]
#   SET_PROJECT_SCANNER=0|1       set the project's scanner to SCANNER_NAME
#   DO_SCAN=0|1                   trigger a scan and capture the result
#   OUT_FILE=<path>               default adapter-triage-<timestamp>.log
#   KUBECTL=oc|kubectl            default oc
#   CURL_OPTS                     extra curl opts for the Harbor API (e.g. -k)
# ==============================================================================
set -uo pipefail

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '2,60p' "$0"; exit 0; }

HARBOR_NS="${HARBOR_NS:?set HARBOR_NS}"
HARBOR_URL="${HARBOR_URL:?set HARBOR_URL}"
HARBOR_PASS="${HARBOR_PASS:?set HARBOR_PASS}"
SCANNER_NAME="${SCANNER_NAME:?set SCANNER_NAME}"
HARBOR_ADMIN="${HARBOR_ADMIN:-admin}"

NV_NS="${NV_NS:-dcs-neuvector}"
NV_ADAPTER_DEPLOY="${NV_ADAPTER_DEPLOY:-neuvector-registry-adapter-pod}"
NV_ADAPTER_SVC="${NV_ADAPTER_SVC:-neuvector-service-registry-adapter}"
NV_CONTROLLER_DEPLOY="${NV_CONTROLLER_DEPLOY:-neuvector-controller-pod}"
NV_SCANNER_DEPLOY="${NV_SCANNER_DEPLOY:-neuvector-scanner-pod}"
NV_ADAPTER_AUTH_SECRET="${NV_ADAPTER_AUTH_SECRET:-dcs-neuvector-adapter-auth}"
NV_INTERNAL_CA_SECRET="${NV_INTERNAL_CA_SECRET:-dcs-neuvector-internal-certs}"

HARBOR_CORE_SELECTOR="${HARBOR_CORE_SELECTOR:-component=core}"
HARBOR_JOBSVC_SELECTOR="${HARBOR_JOBSVC_SELECTOR:-component=jobservice}"
HARBOR_CORE_DEPLOY="${HARBOR_CORE_DEPLOY:-harbor-core}"

TEST_IMAGE="${TEST_IMAGE:-}"
PING_COUNT="${PING_COUNT:-5}"
DO_SCAN="${DO_SCAN:-0}"
SET_PROJECT_SCANNER="${SET_PROJECT_SCANNER:-0}"
K="${KUBECTL:-oc}"
CURL_OPTS="${CURL_OPTS:-}"

OUT_FILE="${OUT_FILE:-adapter-triage-$(date +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$OUT_FILE") 2>&1
echo "### writing to $OUT_FILE — scp this one file when done ###"

# ---- cluster plumbing --------------------------------------------------------
KH_CTX=(); [[ -n "${HARBOR_CONTEXT:-}" ]] && KH_CTX=(--context "$HARBOR_CONTEXT")
KN_CTX=(); [[ -n "${NV_CONTEXT:-}"     ]] && KN_CTX=(--context "$NV_CONTEXT")
kh() { "$K" ${KH_CTX[@]+"${KH_CTX[@]}"} -n "$HARBOR_NS" "$@"; }   # Harbor cluster
kn() { "$K" ${KN_CTX[@]+"${KN_CTX[@]}"} -n "$NV_NS"     "$@"; }   # NeuVector cluster

if [[ -n "${HARBOR_CONTEXT:-}${NV_CONTEXT:-}" && "${HARBOR_CONTEXT:-}" != "${NV_CONTEXT:-}" ]]; then
  MODE="CROSS-CLUSTER"
else
  MODE="SAME-CLUSTER"
fi

sec()  { echo; echo "=================================================================="; echo "== $*"; echo "=================================================================="; }
sub()  { echo; echo "--- $* ---"; }
note() { echo "    # $*"; }
hash12() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -c1-12
  else printf '%s' "$1" | shasum -a 256 | cut -c1-12; fi
}
api()  { curl -sS $CURL_OPTS -u "$HARBOR_ADMIN:$HARBOR_PASS" "$HARBOR_URL/api/v2.0$1"; }
apiw() { curl -sS $CURL_OPTS -u "$HARBOR_ADMIN:$HARBOR_PASS" -o /dev/null -w '%{http_code}' "$HARBOR_URL/api/v2.0$1"; }
jqp()  { python3 -c "$1" 2>/dev/null || echo "    (could not parse response)"; }

# ==============================================================================
sec "0. CONTEXT"
date -u '+%Y-%m-%dT%H:%M:%SZ   (all timestamps UTC)'
cat <<EOF
MODE                 : $MODE
HARBOR_CONTEXT       : ${HARBOR_CONTEXT:-<current context>}
NV_CONTEXT           : ${NV_CONTEXT:-<current context>}
HARBOR_NS / URL      : $HARBOR_NS / $HARBOR_URL
NV_NS                : $NV_NS
adapter deploy / svc : $NV_ADAPTER_DEPLOY / $NV_ADAPTER_SVC
SCANNER_NAME         : $SCANNER_NAME
TEST_IMAGE           : ${TEST_IMAGE:-<unset>}
PING_COUNT           : $PING_COUNT
SET_PROJECT_SCANNER  : $SET_PROJECT_SCANNER      DO_SCAN: $DO_SCAN
EOF
sub "contexts actually reachable"
echo -n "  harbor cluster : "; kh get ns "$HARBOR_NS" -o name 2>&1 | head -1
echo -n "  nv cluster     : "; kn get ns "$NV_NS"     -o name 2>&1 | head -1
if [[ "$MODE" == "CROSS-CLUSTER" ]]; then
  note "Cross-cluster: the adapter MUST be reached over its Route. In-cluster"
  note "Service DNS (*.svc.cluster.local) cannot resolve from the Harbor cluster."
fi

# ==============================================================================
sec "[Q13] HARBOR VERSION"
api /systeminfo | jqp '
import sys,json
d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in
  ("harbor_version","auth_mode","registry_url","external_url")}, indent=2))'

# ==============================================================================
sec "[Q1][Q2][Q3][Q12][Q14] SCANNER REGISTRATION — as Harbor stores it"
api /scanners | jqp '
import sys,json
for r in json.load(sys.stdin):
    print(json.dumps(r, indent=2, sort_keys=True)); print("-"*60)'
note "Q1  url verbatim — must end in /endpoint; :9443 for a Service, no port for a Route"
note "Q2  auth ('' means None) and skip_certVerify"
note "Q3  use_internal_addr"
note "Q12 is_default"
note "Q14 Service DNS vs Route host"

SC_JSON=$(api /scanners)
read -r UUID ENDPOINT REG_TIME <<<"$(printf '%s' "$SC_JSON" | python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if r.get('name')=='$SCANNER_NAME':
        print(r.get('uuid','-'), r.get('url','-'), (r.get('update_time') or r.get('create_time') or '-')); break
else: print('- - -')
" 2>/dev/null)"
echo
echo "resolved uuid      : ${UUID:--}"
echo "resolved endpoint  : ${ENDPOINT:--}"
echo "registered/updated : ${REG_TIME:--}"
[[ "${UUID:-}" == "-" ]] && UUID=""
[[ "${ENDPOINT:-}" == "-" ]] && ENDPOINT=""

# ==============================================================================
sec "[Q8] THE DECISIVE CALL — Harbor's own metadata ping"
note "Same Ping the scan path runs. Capabilities here => r.Metadata is populated"
note "and the mime-type error cannot originate from this call."
if [[ -n "${UUID:-}" ]]; then
  api "/scanners/$UUID/metadata" | jqp '
import sys,json
d=json.load(sys.stdin)
if isinstance(d,dict) and d.get("errors"):
    print("PING FAILED — this is the root cause:"); print(json.dumps(d,indent=2)); raise SystemExit
print("scanner:", json.dumps(d.get("scanner")))
for c in d.get("capabilities") or []:
    print("capability type:", c.get("type"))
    print("  consumes:", c.get("consumes_mime_types"))
    print("  produces:", c.get("produces_mime_types"))
oci="application/vnd.oci.image.manifest.v1+json"
caps=d.get("capabilities") or []
print()
print("OCI manifest advertised :", any(oci in (c.get("consumes_mime_types") or []) for c in caps))
print("SBOM capability present :", any(c.get("type")=="sbom" for c in caps), " # false => Trivy must stay")'
  sub "health as Harbor records it"
  api "/scanners/$UUID" | jqp '
import sys,json;d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in ("name","health","disabled","adapter","vendor","version")},indent=2))'
else
  echo "SCANNER_NAME '$SCANNER_NAME' matched no registration — check the name above"
fi

# ==============================================================================
sec "[Q10] CONSISTENT OR INTERMITTENT?"
if [[ -n "${UUID:-}" ]]; then
  for i in $(seq 1 "$PING_COUNT"); do
    printf "  attempt %-2s HTTP %s\n" "$i" "$(apiw "/scanners/$UUID/metadata")"
    sleep 1
  done
  note "Harbor caches BOTH success and failure for 30s per core pod, so identical"
  note "answers inside 30s prove nothing on their own — the per-pod probe below does."
fi

sub "[Q5] harbor-core pods (Harbor cluster)"
kh get pods -l "$HARBOR_CORE_SELECTOR" \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,STARTED:.status.startTime,NODE:.spec.nodeName
CORE_PODS=$(kh get pods -l "$HARBOR_CORE_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
echo "core replica count: $(echo "$CORE_PODS" | wc -w | tr -d ' ')"

sub "[Q15] harbor-jobservice pods (Harbor cluster)"
kh get pods -l "$HARBOR_JOBSVC_SELECTOR" \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,STARTED:.status.startTime
note "jobservice runs the scan job itself; it needs the same trust as core."

# ==============================================================================
sec "[Q5][Q10] PER-POD PROBE — isolates one stale replica"
if [[ -n "${ENDPOINT:-}" && -n "${CORE_PODS:-}" ]]; then
  for p in $CORE_PODS; do
    sub "from core pod $p"
    kh exec "$p" -- sh -c \
      "command -v curl >/dev/null 2>&1 || { echo 'no curl in image — skipping'; exit 0; };
       printf 'verify-TLS : '; curl -sS  -o /dev/null -w '%{http_code}\n' --max-time 10 '${ENDPOINT}/api/v1/metadata' 2>&1 | tail -1;
       printf 'skip-TLS   : '; curl -sSk -o /dev/null -w '%{http_code}\n' --max-time 10 '${ENDPOINT}/api/v1/metadata' 2>&1 | tail -1" \
      2>&1 | sed 's/^/  /'
  done
  note "401 skip-TLS          -> reachable + TLS fine, credentials wrong"
  note "200 skip / fail verify-> trust problem only"
  note "both fail on ONE pod  -> that replica is stale; restart it"
  note "all fail identically  -> network path, auth, or the adapter is not listening"
fi

sub "[Q-proxy] proxy env on harbor-core"
kh set env "deploy/$HARBOR_CORE_DEPLOY" --list 2>/dev/null | grep -iE "proxy" \
  || echo "  no proxy env (or set HARBOR_CORE_DEPLOY)"
note "HTTPS_PROXY set + adapter host missing from NO_PROXY => Go error 'Forbidden'"

sub "[Q-trust] custom CA material inside core"
FIRST_CORE=$(echo "$CORE_PODS" | awk '{print $1}')
if [[ -n "${FIRST_CORE:-}" ]]; then
  kh exec "$FIRST_CORE" -- sh -c \
    'ls -la /harbor_cust_cert/ 2>/dev/null || echo "no /harbor_cust_cert";
     for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
       [ -f "$f" ] && echo "$f: $(grep -c "BEGIN CERTIFICATE" "$f") certs"; done' 2>&1 | sed 's/^/  /'
fi

# ==============================================================================
sec "[Q14] THE ENDPOINT SEEN FROM OUTSIDE (matters most in CROSS-CLUSTER)"
if [[ -n "${ENDPOINT:-}" ]]; then
  EP_HOST=$(python3 -c "
import urllib.parse,sys
u=urllib.parse.urlparse('$ENDPOINT'); print(u.hostname or '')
print(u.port or (443 if u.scheme=='https' else 80))" 2>/dev/null)
  EHOST=$(echo "$EP_HOST" | sed -n 1p); EPORT=$(echo "$EP_HOST" | sed -n 2p)
  echo "endpoint host:port = ${EHOST}:${EPORT}"
  if [[ "$EHOST" == *.svc.cluster.local || "$EHOST" == *.svc ]]; then
    echo "  -> in-cluster Service DNS"
    [[ "$MODE" == "CROSS-CLUSTER" ]] && echo "  !! CROSS-CLUSTER but registered with Service DNS — cannot resolve from Harbor"
  else
    echo "  -> external hostname (Route/LB)"
    sub "certificate served at ${EHOST}:${EPORT}, from this workstation"
    echo | openssl s_client -connect "${EHOST}:${EPORT}" -servername "$EHOST" 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/  /' \
      || echo "  could not complete TLS from here (may simply be firewalled off your laptop)"
    sub "metadata endpoint from this workstation"
    printf "  verify-TLS : "; curl -sS  -o /dev/null -w '%{http_code}\n' --max-time 10 "${ENDPOINT}/api/v1/metadata" 2>&1 | tail -1
    printf "  skip-TLS   : "; curl -sSk -o /dev/null -w '%{http_code}\n' --max-time 10 "${ENDPOINT}/api/v1/metadata" 2>&1 | tail -1
    note "Compare with the per-pod probe: same result => shared cause;"
    note "works here but not from core => core-specific trust or proxy."
  fi
fi

# ==============================================================================
sec "[Q4][Q6] TIMELINE — did anything restart after registration?"
echo "scanner registered/updated : ${REG_TIME:-unknown}"
sub "NeuVector pods (NV cluster)"
kn get pods -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,STARTED:.status.startTime
note "Q4 adapter STARTED after registration => it restarted since; re-check it is listening"
note "Q6 controller/scanner STARTED after registration matters: the adapter blocks"
note "   before it listens until it can read the scanner version from the controller"

# ==============================================================================
sec "[Q-adapter] ADAPTER — wiring, cert, listening state (NV cluster)"
kn get deploy "$NV_ADAPTER_DEPLOY" -o yaml 2>/dev/null \
  | grep -E "image:|name: HARBOR_|name: CLUSTER_JOIN_ADDR|secretName:|mountPath:|subPath:" \
  || echo "adapter deployment '$NV_ADAPTER_DEPLOY' not found — set NV_ADAPTER_DEPLOY"

sub "service"
kn get svc "$NV_ADAPTER_SVC" -o yaml 2>/dev/null \
  | grep -E "^  name:|port:|targetPort:|type:|appProtocol" || echo "  service not found"

sub "routes in $NV_NS"
kn get route -o custom-columns=NAME:.metadata.name,HOST:.spec.host,TARGETPORT:.spec.port.targetPort,TLS:.spec.tls.termination 2>/dev/null \
  || echo "  no routes (or not OpenShift)"

sub "adapter log — FIRST 40 lines (the ones that matter)"
kn logs "deploy/$NV_ADAPTER_DEPLOY" --tail=400 2>/dev/null | head -40
note "'START - version=...' then silence => still blocked in for nvScanner.Version==\"\""
note "and NOT listening on 9443 at all."
sub "adapter log — LAST 40 lines"
kn logs "deploy/$NV_ADAPTER_DEPLOY" --tail=40 2>/dev/null

sub "certificate the adapter serves"
ADAPTER_CERT_SECRET="${NV_ADAPTER_CERT_SECRET:-$(kn get deploy "$NV_ADAPTER_DEPLOY" \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="cert")].secret.secretName}' 2>/dev/null)}"
echo "  cert secret: ${ADAPTER_CERT_SECRET:-<none — adapter generated a self-signed cert>}"
if [[ -n "${ADAPTER_CERT_SECRET:-}" ]]; then
  kn get secret "$ADAPTER_CERT_SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/  /'
  note "For a Route the SAN must equal the Route host exactly."
fi

sub "internal CA + cert-manager renewal timing"
kn get secret "$NV_INTERNAL_CA_SECRET" -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
  | base64 -d | openssl x509 -noout -subject -dates -fingerprint -sha256 2>/dev/null | sed 's/^/  /' \
  || echo "  no $NV_INTERNAL_CA_SECRET"
kn get certificate 2>/dev/null \
  -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status,NOTAFTER:.status.notAfter,RENEWAL:.status.renewalTime

sub "adapter credential fingerprints (values never printed)"
AU=$(kn get secret "$NV_ADAPTER_AUTH_SECRET" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
AP=$(kn get secret "$NV_ADAPTER_AUTH_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [[ -n "${AU:-}" ]]; then
  echo "  username sha256[0:12]=$(hash12 "$AU")  len=${#AU}"
  echo "  password sha256[0:12]=$(hash12 "$AP")  len=${#AP}"
  note "Harbor does not expose its stored copy via API — compare in the edit dialog,"
  note "or simply re-enter both sides to guarantee they match."
else
  echo "  secret $NV_ADAPTER_AUTH_SECRET not found or missing username/password keys"
  note "With the env vars unset the adapter answers an empty 200 and Harbor reports"
  note "'invalid character ... looking for beginning of value'."
fi

# ==============================================================================
sec "[Q6] NEUVECTOR CONTROLLER / SCANNER"
kn get deploy "$NV_CONTROLLER_DEPLOY" "$NV_SCANNER_DEPLOY" 2>/dev/null \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas
sub "controller log — config / TLS lines"
kn logs "deploy/$NV_CONTROLLER_DEPLOY" --tail=200 2>/dev/null \
  | grep -iE "initcfg|cacert|tls|verif" | tail -20

# ==============================================================================
sec "[Q9][Q11][Q12] TEST ARTIFACT AND ITS SCAN HISTORY"
if [[ -z "$TEST_IMAGE" ]]; then
  echo "TEST_IMAGE not set. Candidate projects and repositories:"
  api "/projects?page_size=20" | jqp '
import sys,json
for p in json.load(sys.stdin): print("  project:", p.get("name"), " repos:", p.get("repo_count"))'
  note "Pick any project you control and set TEST_IMAGE=project/repo:tag"
else
  PROJ="${TEST_IMAGE%%/*}"; REST="${TEST_IMAGE#*/}"
  REPO="${REST%%:*}"; REF="${REST##*:}"
  ENC=$(python3 -c "import urllib.parse;print(urllib.parse.quote(urllib.parse.quote('$REPO',safe=''),safe=''))")
  echo "project=$PROJ repo=$REPO ref=$REF"

  sub "[Q12] scanner currently configured FOR THIS PROJECT"
  api "/projects/$PROJ/scanner" | jqp '
import sys,json;d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in ("uuid","name","url","is_default","health")},indent=2))'
  PREV_SCANNER=$(api "/projects/$PROJ/scanner" | python3 -c "
import sys,json;print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null)
  note "A scan uses THIS scanner. If it is Trivy, the scan never touches NeuVector."

  if [[ "$SET_PROJECT_SCANNER" == "1" && -n "${UUID:-}" ]]; then
    sub "SET_PROJECT_SCANNER=1 — pointing project $PROJ at $SCANNER_NAME (MUTATION)"
    echo "previous scanner uuid: ${PREV_SCANNER:-none}"
    curl -sS $CURL_OPTS -u "$HARBOR_ADMIN:$HARBOR_PASS" -X PUT \
      -H 'Content-Type: application/json' -o /dev/null -w 'PUT scanner -> HTTP %{http_code}\n' \
      -d "{\"uuid\":\"$UUID\"}" "$HARBOR_URL/api/v2.0/projects/$PROJ/scanner"
    echo "RESTORE LATER WITH:"
    echo "  curl -u '$HARBOR_ADMIN:<pass>' -X PUT -H 'Content-Type: application/json' \\"
    echo "    -d '{\"uuid\":\"${PREV_SCANNER}\"}' $HARBOR_URL/api/v2.0/projects/$PROJ/scanner"
  fi

  sub "artifact type / media type / scan overview"
  api "/projects/$PROJ/repositories/$ENC/artifacts/$REF?with_scan_overview=true&with_accessory=true" | jqp '
import sys,json
a=json.load(sys.stdin)
if isinstance(a,dict) and a.get("errors"): print(json.dumps(a,indent=2)); raise SystemExit
print(json.dumps({
 "type": a.get("type"),
 "media_type": a.get("media_type"),
 "manifest_media_type": a.get("manifest_media_type"),
 "digest": a.get("digest"),
 "is_image_index": bool(a.get("references")),
 "accessories": [x.get("type") for x in (a.get("accessories") or [])],
}, indent=2))
print()
print("scan_overview (one entry per report mime type):")
for mt,rep in (a.get("scan_overview") or {}).items():
    print(" ", mt, "->", json.dumps({k:rep.get(k) for k in
      ("scan_status","severity","report_id","start_time","end_time","scanner")}))'
  note "Q9  type must be IMAGE. Anything else and no scanner can scan it."
  note "Q11 compare digest with what Trivy scanned; the scanner field inside"
  note "    scan_overview names which scanner produced each report."

  sub "[Q9] media-type mix in this repository (up to 20 artifacts)"
  api "/projects/$PROJ/repositories/$ENC/artifacts?page_size=20" | jqp '
import sys,json
rows=json.load(sys.stdin)
if isinstance(rows,dict): print(json.dumps(rows)); raise SystemExit
for a in rows:
    tag=(a.get("tags") or [{}])[0].get("name") if a.get("tags") else "<untagged>"
    print(" ", a.get("type"), a.get("manifest_media_type"), tag)'

  if [[ "$DO_SCAN" == "1" ]]; then
    sub "[Q7] DO_SCAN=1 — triggering a scan (MUTATION)"
    curl -sS $CURL_OPTS -u "$HARBOR_ADMIN:$HARBOR_PASS" -X POST -o /dev/null \
      -w 'POST scan -> HTTP %{http_code}\n' \
      "$HARBOR_URL/api/v2.0/projects/$PROJ/repositories/$ENC/artifacts/$REF/scan"
    echo "waiting 25s for the job..."; sleep 25
    api "/projects/$PROJ/repositories/$ENC/artifacts/$REF?with_scan_overview=true" | jqp '
import sys,json
for mt,rep in (json.load(sys.stdin).get("scan_overview") or {}).items():
    print(" ",mt,"->",json.dumps({k:rep.get(k) for k in ("scan_status","severity","scanner")}))'
  else
    note "DO_SCAN=1 reproduces the failure inside this run; the log section below"
    note "then captures the core log lines it produces."
  fi
fi

# ==============================================================================
sec "[Q7] SCAN-ALL SCHEDULE (are scans also auto-triggered?)"
api /system/scanAll/schedule | jqp 'import sys,json;print(json.dumps(json.load(sys.stdin),indent=2))'

# ==============================================================================
sec "THE REAL ERROR — core logs, where it hides under a different prefix"
for p in $CORE_PODS; do
  sub "core pod $p"
  kh logs "$p" --tail=5000 2>/dev/null \
    | grep -E "api controller: get project scanner|scanner controller: ping|does not support scanning artifact|registry-adapter|failed to ping scanner" \
    | tail -25
done
note "'api controller: get project scanner' carries the ACTUAL failure."
note "'does not support scanning artifact' is only its downstream symptom."

sub "jobservice logs"
kh logs -l "$HARBOR_JOBSVC_SELECTOR" --tail=2000 2>/dev/null \
  | grep -iE "scan|adapter|x509|refused|timeout" | tail -25

sec "END"
echo "Collected to: $OUT_FILE"
echo "scp it over as-is — credentials are fingerprints only."
