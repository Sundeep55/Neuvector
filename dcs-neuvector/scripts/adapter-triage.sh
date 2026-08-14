#!/usr/bin/env bash
# ==============================================================================
# adapter-triage.sh — one-shot data collection for a NeuVector registry adapter
# / Harbor pluggable-scanner failure.
#
# Sections are tagged [Qn] with the triage question they answer, so the output
# maps straight back to the checklist.
#
# READ-ONLY by default. Nothing is created or changed unless you opt in with
# DO_SCAN=1. Credentials are never printed — only SHA-256 prefixes, so the two
# sides can be compared without the value appearing anywhere.
#
# ------------------------------------------------------------------------------
# REQUIRED
#   HARBOR_NS           namespace Harbor runs in
#   HARBOR_URL          e.g. https://registry.x.com
#   HARBOR_PASS         admin password  (read -rs HARBOR_PASS && export HARBOR_PASS)
#   SCANNER_NAME        the registration name, e.g. neuvector-qa
#
# OPTIONAL — override any name that differs in your environment
#   NV_NS                       default dcs-neuvector
#   NV_ADAPTER_DEPLOY           default neuvector-registry-adapter-pod
#   NV_ADAPTER_SVC              default neuvector-service-registry-adapter
#   NV_CONTROLLER_DEPLOY        default neuvector-controller-pod
#   NV_SCANNER_DEPLOY           default neuvector-scanner-pod
#   NV_ADAPTER_AUTH_SECRET      default dcs-neuvector-adapter-auth
#   NV_INTERNAL_CA_SECRET       default dcs-neuvector-internal-certs
#   HARBOR_CORE_SELECTOR        default component=core
#   HARBOR_JOBSVC_SELECTOR      default component=jobservice
#   HARBOR_CORE_DEPLOY          default harbor-core
#   HARBOR_ADMIN                default admin
#   TEST_IMAGE                  project/repo:tag that failed — enables [Q9][Q11]
#   PING_COUNT                  metadata pings per core pod (default 5) — [Q10]
#   DO_SCAN                     1 = actually trigger a scan of TEST_IMAGE [Q7]
#   KUBECTL                     oc | kubectl (default oc)
#   CURL_OPTS                   extra curl opts for the Harbor API (e.g. -k)
#
# Usage:
#   ./adapter-triage.sh > triage-$(date +%Y%m%d-%H%M).txt 2>&1
# ==============================================================================
set -uo pipefail

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
K="${KUBECTL:-oc}"
CURL_OPTS="${CURL_OPTS:-}"

# ------------------------------------------------------------------------------
sec()  { echo; echo "=================================================================="; echo "== $*"; echo "=================================================================="; }
sub()  { echo; echo "--- $* ---"; }
note() { echo "    # $*"; }
hash12() {
  if command -v sha256sum >/dev/null; then printf '%s' "$1" | sha256sum | cut -c1-12
  else printf '%s' "$1" | shasum -a 256 | cut -c1-12; fi
}
api() { curl -sS $CURL_OPTS -u "$HARBOR_ADMIN:$HARBOR_PASS" "$HARBOR_URL/api/v2.0$1"; }
jqp() { python3 -c "$1" 2>/dev/null || echo "    (could not parse response)"; }

sec "0. CONTEXT"
date -u '+%Y-%m-%dT%H:%M:%SZ  (all timestamps below are UTC)'
cat <<EOF
NV_NS=$NV_NS
NV_ADAPTER_DEPLOY=$NV_ADAPTER_DEPLOY   NV_ADAPTER_SVC=$NV_ADAPTER_SVC
NV_CONTROLLER_DEPLOY=$NV_CONTROLLER_DEPLOY   NV_SCANNER_DEPLOY=$NV_SCANNER_DEPLOY
HARBOR_NS=$HARBOR_NS   HARBOR_URL=$HARBOR_URL
SCANNER_NAME=$SCANNER_NAME   TEST_IMAGE=${TEST_IMAGE:-<unset>}
PING_COUNT=$PING_COUNT   DO_SCAN=$DO_SCAN
EOF

# ==============================================================================
sec "[Q13] HARBOR VERSION"
api /systeminfo | jqp '
import sys,json
d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in
  ("harbor_version","auth_mode","registry_url","external_url",
   "with_notary","notification_enable","banner_message")}, indent=2))'

# ==============================================================================
sec "[Q1][Q2][Q3][Q12][Q14] SCANNER REGISTRATION — exactly as Harbor stores it"
api /scanners | jqp '
import sys,json
rows=json.load(sys.stdin)
for r in rows:
    print(json.dumps(r, indent=2, sort_keys=True))
    print("-"*60)'
note "Q1  = the url field, verbatim. Must end in /endpoint and carry :9443"
note "     unless it is a passthrough Route (then no port)."
note "Q2  = auth (empty string means None) and skip_certVerify."
note "Q3  = use_internal_addr."
note "Q12 = is_default."
note "Q14 = whether url is a .svc.cluster.local name or a Route host."

UUID=$(api /scanners | python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if r.get('name')=='$SCANNER_NAME': print(r['uuid']); break
" 2>/dev/null)
ENDPOINT=$(api /scanners | python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if r.get('name')=='$SCANNER_NAME': print(r['url']); break
" 2>/dev/null)
REG_CREATED=$(api /scanners | python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if r.get('name')=='$SCANNER_NAME': print(r.get('update_time') or r.get('create_time')); break
" 2>/dev/null)
echo
echo "resolved uuid     : ${UUID:-NOT FOUND}"
echo "resolved endpoint : ${ENDPOINT:-NOT FOUND}"
echo "registered/updated: ${REG_CREATED:-unknown}"

# ==============================================================================
sec "[Q8] THE DECISIVE CALL — Harbor's own metadata ping"
note "This is the same Ping the scan path runs. If it returns capabilities,"
note "r.Metadata is populated and the mime-type error cannot come from here."
if [[ -n "${UUID:-}" ]]; then
  api "/scanners/$UUID/metadata" | jqp '
import sys,json
d=json.load(sys.stdin)
if isinstance(d,dict) and d.get("errors"):
    print("PING FAILED — this is the root cause:"); print(json.dumps(d,indent=2)); raise SystemExit
print("scanner   :", json.dumps(d.get("scanner")))
for c in d.get("capabilities") or []:
    print("capability:", c.get("type"))
    print("  consumes:", c.get("consumes_mime_types"))
    print("  produces:", c.get("produces_mime_types"))
print("properties:", json.dumps(d.get("properties")))
oci="application/vnd.oci.image.manifest.v1+json"
ok=any(oci in (c.get("consumes_mime_types") or []) for c in (d.get("capabilities") or []))
print()
print("OCI manifest advertised:", ok)
sbom=any(c.get("type")=="sbom" for c in (d.get("capabilities") or []))
print("SBOM capability        :", sbom, "   # [Q-SBOM] false = Trivy must stay")'
  sub "scanner health field"
  api "/scanners/$UUID" | jqp '
import sys,json;d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in ("name","health","disabled","adapter","vendor","version")},indent=2))'
else
  echo "cannot ping — SCANNER_NAME did not match any registration"
fi

# ==============================================================================
sec "[Q10] IS IT CONSISTENT? — repeat the ping, and hit every core pod"
note "Different results across pods means the replicas are not identical"
note "(typically: only some were restarted after the CA bundle changed)."
if [[ -n "${UUID:-}" ]]; then
  sub "via the Harbor service ($PING_COUNT attempts)"
  for i in $(seq 1 "$PING_COUNT"); do
    code=$(curl -sS $CURL_OPTS -o /dev/null -w '%{http_code}' \
      -u "$HARBOR_ADMIN:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/scanners/$UUID/metadata")
    printf "  attempt %-2s HTTP %s\n" "$i" "$code"
    sleep 1
  done
  note "metadata results (success AND failure) are cached 30s per core pod,"
  note "so identical answers inside 30s are expected — the loop above sleeps 1s"
  note "between attempts; re-run this script after 60s to sample a fresh window."
fi

sub "[Q5] harbor-core pods"
$K -n "$HARBOR_NS" get pods -l "$HARBOR_CORE_SELECTOR" \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,STARTED:.status.startTime,NODE:.spec.nodeName
CORE_PODS=$($K -n "$HARBOR_NS" get pods -l "$HARBOR_CORE_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
echo "core replica count: $(echo $CORE_PODS | wc -w | tr -d ' ')"

sub "[Q15] harbor-jobservice pods"
$K -n "$HARBOR_NS" get pods -l "$HARBOR_JOBSVC_SELECTOR" \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,STARTED:.status.startTime
note "jobservice runs the scan job itself. If it was not restarted after the"
note "CA change it will fail later even once core works."

# ==============================================================================
sec "[Q5][Q10] PER-POD PROBE — the test that isolates a bad replica"
if [[ -n "${ENDPOINT:-}" && -n "${CORE_PODS:-}" ]]; then
  for p in $CORE_PODS; do
    sub "from pod $p"
    $K -n "$HARBOR_NS" exec "$p" -- sh -c \
      "command -v curl >/dev/null || { echo '    no curl in image — skipping'; exit 0; };
       echo -n '    verify-TLS : '; curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 '${ENDPOINT}/api/v1/metadata' 2>&1 | tail -1;
       echo -n '    skip-TLS   : '; curl -sSk -o /dev/null -w '%{http_code}\n' --max-time 10 '${ENDPOINT}/api/v1/metadata' 2>&1 | tail -1" \
      2>&1 | sed 's/^/  /'
  done
  note "401 on skip-TLS = reachable, TLS fine, credentials wrong."
  note "200 on skip-TLS but failure on verify-TLS = trust problem only."
  note "Both failing on ONE pod only = that replica is stale — restart it."
fi

sub "[Q-proxy] proxy environment on harbor-core"
$K -n "$HARBOR_NS" set env "deploy/$HARBOR_CORE_DEPLOY" --list 2>/dev/null | grep -iE "proxy" \
  || echo "no proxy env (or deployment name differs — set HARBOR_CORE_DEPLOY)"
note "A set HTTPS_PROXY whose NO_PROXY misses the adapter host produces"
note "the Go error 'Forbidden' (a refused proxy CONNECT)."

sub "[Q-trust] custom CA material inside core"
FIRST_CORE=$(echo $CORE_PODS | awk '{print $1}')
if [[ -n "${FIRST_CORE:-}" ]]; then
  $K -n "$HARBOR_NS" exec "$FIRST_CORE" -- sh -c \
    'ls -la /harbor_cust_cert/ 2>/dev/null || echo "no /harbor_cust_cert";
     for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
       [ -f "$f" ] && echo "$f: $(grep -c "BEGIN CERTIFICATE" "$f") certs"; done' 2>&1 | sed 's/^/  /'
fi

# ==============================================================================
sec "[Q4][Q6] TIMELINE — did anything restart after the scanner was registered?"
echo "scanner registered/updated : ${REG_CREATED:-unknown}"
sub "NeuVector pods"
$K -n "$NV_NS" get pods \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,STARTED:.status.startTime
sub "NeuVector deployments"
$K -n "$NV_NS" get deploy \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,AGE:.metadata.creationTimestamp
note "Q4: adapter STARTED later than 'scanner registered' means the adapter"
note "    restarted after registration — it may not be listening (see Q-adapter)."
note "Q6: controller/scanner STARTED after registration matters because the"
note "    adapter blocks before listening until it can read the scanner version."

# ==============================================================================
sec "[Q-adapter] ADAPTER — wiring, cert, and whether it is actually listening"
$K -n "$NV_NS" get deploy "$NV_ADAPTER_DEPLOY" -o yaml 2>/dev/null \
  | grep -E "image:|name: HARBOR_|name: CLUSTER_JOIN_ADDR|secretName:|mountPath:|subPath:" \
  || echo "adapter deployment '$NV_ADAPTER_DEPLOY' not found — set NV_ADAPTER_DEPLOY"

sub "service"
$K -n "$NV_NS" get svc "$NV_ADAPTER_SVC" -o yaml 2>/dev/null \
  | grep -E "^  name:|port:|targetPort:|type:|appProtocol" || echo "service not found"

sub "routes in $NV_NS"
$K -n "$NV_NS" get route -o custom-columns=NAME:.metadata.name,HOST:.spec.host,TARGETPORT:.spec.port.targetPort,TLS:.spec.tls.termination 2>/dev/null \
  || echo "no routes (or not OpenShift)"

sub "adapter logs — first 40 lines are the ones that matter"
$K -n "$NV_NS" logs "deploy/$NV_ADAPTER_DEPLOY" --tail=400 2>/dev/null | head -40
note "'START - version=...' followed by nothing means it is still blocked in"
note "for nvScanner.Version == \"\" and is NOT listening on 9443 at all."
sub "adapter logs — last 40 lines"
$K -n "$NV_NS" logs "deploy/$NV_ADAPTER_DEPLOY" --tail=40 2>/dev/null

sub "certificate the adapter actually serves"
ADAPTER_CERT_SECRET="${NV_ADAPTER_CERT_SECRET:-$($K -n "$NV_NS" get deploy "$NV_ADAPTER_DEPLOY" \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="cert")].secret.secretName}' 2>/dev/null)}"
echo "cert secret: ${ADAPTER_CERT_SECRET:-<none — adapter generated its own self-signed cert>}"
if [[ -n "${ADAPTER_CERT_SECRET:-}" ]]; then
  $K -n "$NV_NS" get secret "$ADAPTER_CERT_SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
    | sed 's/^/  /'
fi
sub "internal CA (what Harbor must trust) and renewal timing"
$K -n "$NV_NS" get secret "$NV_INTERNAL_CA_SECRET" -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
  | base64 -d | openssl x509 -noout -subject -dates -fingerprint -sha256 2>/dev/null | sed 's/^/  /' \
  || echo "  no $NV_INTERNAL_CA_SECRET"
$K -n "$NV_NS" get certificate 2>/dev/null \
  -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status,NOTAFTER:.status.notAfter,RENEWAL:.status.renewalTime

sub "adapter credential fingerprints (values never printed)"
AU=$($K -n "$NV_NS" get secret "$NV_ADAPTER_AUTH_SECRET" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
AP=$($K -n "$NV_NS" get secret "$NV_ADAPTER_AUTH_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [[ -n "${AU:-}" ]]; then
  echo "  username sha256[0:12]=$(hash12 "$AU")  len=${#AU}"
  echo "  password sha256[0:12]=$(hash12 "$AP")  len=${#AP}"
  note "Compare with what is stored in Harbor's registration (Harbor does not"
  note "expose it via API — check the edit dialog, or just re-enter both sides)."
else
  echo "  secret $NV_ADAPTER_AUTH_SECRET not found, or no username/password keys"
  note "If the env vars are unset the adapter answers an empty 200 and Harbor"
  note "reports 'invalid character ... looking for beginning of value'."
fi

# ==============================================================================
sec "[Q6] NEUVECTOR CONTROLLER / SCANNER READINESS"
$K -n "$NV_NS" get deploy "$NV_CONTROLLER_DEPLOY" "$NV_SCANNER_DEPLOY" 2>/dev/null \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas
sub "controller log — declarative config / TLS lines"
$K -n "$NV_NS" logs "deploy/$NV_CONTROLLER_DEPLOY" --tail=200 2>/dev/null \
  | grep -iE "initcfg|cacert|tls|verif" | tail -20

# ==============================================================================
sec "[Q9][Q11] THE ARTIFACT AND ITS SCAN HISTORY"
if [[ -n "$TEST_IMAGE" ]]; then
  PROJ="${TEST_IMAGE%%/*}"; REST="${TEST_IMAGE#*/}"
  REPO="${REST%%:*}"; REF="${REST##*:}"
  ENC=$(python3 -c "import urllib.parse;print(urllib.parse.quote(urllib.parse.quote('$REPO',safe=''),safe=''))")
  echo "project=$PROJ repo=$REPO ref=$REF"

  sub "[Q12] scanner configured for project $PROJ"
  api "/projects/$PROJ/scanner" | jqp '
import sys,json;d=json.load(sys.stdin)
print(json.dumps({k:d.get(k) for k in ("uuid","name","url","is_default","health")},indent=2))'

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
so=a.get("scan_overview") or {}
print()
print("scan_overview (one entry per report mime type):")
for mt,rep in so.items():
    print(" ", mt, "->", json.dumps({k:rep.get(k) for k in
      ("scan_status","severity","report_id","start_time","end_time","scanner")}))'
  note "Q9  : type must be IMAGE. Anything else and NO scanner can scan it."
  note "Q11 : compare the digest above with what Trivy scanned, and read the"
  note "      scanner field inside scan_overview to see which one produced it."

  sub "[Q9] media-type mix in project $PROJ (first 20 artifacts)"
  api "/projects/$PROJ/repositories?page_size=5" | jqp '
import sys,json
for r in json.load(sys.stdin)[:5]: print(" repo:", r.get("name"))'
  api "/projects/$PROJ/repositories/$ENC/artifacts?page_size=20" | jqp '
import sys,json
rows=json.load(sys.stdin)
if isinstance(rows,dict): print(json.dumps(rows)); raise SystemExit
for a in rows:
    print(" ", a.get("type"), a.get("manifest_media_type"),
          (a.get("tags") or [{}])[0].get("name") if a.get("tags") else "<untagged>")'

  if [[ "$DO_SCAN" == "1" ]]; then
    sub "[Q7] TRIGGERING A SCAN (DO_SCAN=1) — this mutates state"
    curl -sS $CURL_OPTS -o /dev/null -w 'POST scan -> HTTP %{http_code}\n' \
      -u "$HARBOR_ADMIN:$HARBOR_PASS" -X POST \
      "$HARBOR_URL/api/v2.0/projects/$PROJ/repositories/$ENC/artifacts/$REF/scan"
    echo "waiting 20s for the job to run..."; sleep 20
    api "/projects/$PROJ/repositories/$ENC/artifacts/$REF?with_scan_overview=true" | jqp '
import sys,json
so=(json.load(sys.stdin).get("scan_overview") or {})
for mt,rep in so.items(): print(" ",mt,"->",json.dumps({k:rep.get(k) for k in ("scan_status","severity","scanner")}))'
  else
    note "Set DO_SCAN=1 to reproduce the failure inside this run and capture the"
    note "core log lines it produces (section below picks them up)."
  fi
else
  echo "TEST_IMAGE not set — [Q9] and [Q11] skipped"
fi

# ==============================================================================
sec "[Q7] SCAN-ALL SCHEDULE (tells you whether scans are also auto-triggered)"
api /system/scanAll/schedule | jqp '
import sys,json;d=json.load(sys.stdin)
print(json.dumps(d,indent=2))'

# ==============================================================================
sec "THE REAL ERROR — core logs, where it hides under a different prefix"
for p in $CORE_PODS; do
  sub "pod $p"
  $K -n "$HARBOR_NS" logs "$p" --tail=5000 2>/dev/null \
    | grep -E "api controller: get project scanner|scanner controller: ping|does not support scanning artifact|registry-adapter|failed to ping scanner" \
    | tail -25
done
note "'api controller: get project scanner' carries the ACTUAL failure."
note "'does not support scanning artifact' is only its downstream symptom."

sub "jobservice logs"
$K -n "$HARBOR_NS" logs -l "$HARBOR_JOBSVC_SELECTOR" --tail=2000 2>/dev/null \
  | grep -iE "scan|adapter|x509|refused|timeout" | tail -25

sec "END — attach this whole file"
