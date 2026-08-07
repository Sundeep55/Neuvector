#!/usr/bin/env bash
# ==============================================================================
# mirror-images.sh — mirror the NeuVector images this chart needs into Harbor.
#
# Run once on the internet-connected side to seed the mirror. Day-to-day, the
# SCANNER tag is what must keep moving: it carries the CVE database, and the
# in-cluster updater CronJob only restarts the scanner Deployment to force a
# re-pull. Everything else is pinned and only moves on a version upgrade.
#
# Recommended standing setup instead of cron-ing this script:
#   Harbor replication rule (internet Harbor <- docker.io/neuvector), nightly,
#   filter tag: 6  +  4.*  (excluding *-b), then Harbor->Harbor replication into
#   the airgapped instance at 02:00.
#
# Requires: skopeo (or set USE_DOCKER=1 to use docker pull/tag/push).
# ==============================================================================
set -euo pipefail

SRC="${SRC:-docker.io/neuvector}"
DST="${DST:-registry.x.com/internal-images}"

NV_VERSION="${NV_VERSION:-5.6.0}"
UPDATER_TAG="${UPDATER_TAG:-0.0.13}"
ADAPTER_TAG="${ADAPTER_TAG:-0.2.9}"
# Moving major-version stream, refreshed daily upstream. Not `latest`, so a
# disallow-latest-tag admission policy still passes.
SCANNER_TAG="${SCANNER_TAG:-6}"

IMAGES=(
  "controller:${NV_VERSION}"
  "enforcer:${NV_VERSION}"
  "manager:${NV_VERSION}"
  "updater:${UPDATER_TAG}"
  "scanner:${SCANNER_TAG}"
)
# Only needed if cve.adapter.enabled=true (hub, Harbor pluggable scanner).
[[ "${WITH_ADAPTER:-0}" == "1" ]] && IMAGES+=( "registry-adapter:${ADAPTER_TAG}" )

for img in "${IMAGES[@]}"; do
  echo "==> ${SRC}/${img}  ->  ${DST}/${img}"
  if [[ "${USE_DOCKER:-0}" == "1" ]]; then
    docker pull  "${SRC}/${img}"
    docker tag   "${SRC}/${img}" "${DST}/${img}"
    docker push  "${DST}/${img}"
  else
    skopeo copy --all "docker://${SRC}/${img}" "docker://${DST}/${img}"
  fi
done

# Audit aid: also mirror today's dated scanner build alongside the moving tag.
# The digest is identical to :6, so this costs no extra storage in Harbor and
# gives you a dated record of when the CVE database last actually moved.
if [[ "${WITH_DATED_SCANNER:-1}" == "1" ]] && command -v skopeo >/dev/null; then
  DATED="$(skopeo list-tags "docker://${SRC}/scanner" \
            | grep -oE '"4\.[0-9]+"' | tr -d '"' | sort -t. -k2 -n | tail -1)"
  if [[ -n "$DATED" ]]; then
    echo "==> ${SRC}/scanner:${DATED}  ->  ${DST}/scanner:${DATED}  (audit tag)"
    skopeo copy --all "docker://${SRC}/scanner:${DATED}" "docker://${DST}/scanner:${DATED}"
  fi
fi

echo
echo "Verify the moving tag actually moved (digest should change day to day):"
echo "  skopeo inspect docker://${DST}/scanner:${SCANNER_TAG} | jq -r .Digest"
