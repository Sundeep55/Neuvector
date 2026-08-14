Let me build you a single collector so this is one run and one paste-back.

Script is in and smoke-tested (it degrades gracefully when things are missing): [scripts/adapter-triage.sh](dcs-neuvector/scripts/adapter-triage.sh). Read-only, and it prints only SHA-256 prefixes of credentials so you can compare the two sides without pasting secrets anywhere.

```bash
export HARBOR_NS=harbor
export HARBOR_URL=https://registry.x.com
export HARBOR_ADMIN=admin
read -rs HARBOR_PASS && export HARBOR_PASS
export SCANNER_NAME=neuvector-qa
export TEST_IMAGE=myproject/myapp:1.2.3     # the exact artifact that failed
./dcs-neuvector/scripts/adapter-triage.sh > triage.txt 2>&1
```

Attach `triage.txt` whole. It collects ten sections; three of them will almost certainly contain the answer on their own:

- **§6b** — `GET /api/v2.0/scanners/{uuid}/metadata`. This is the *same ping the scan path makes*. If it returns `consumes_mime_types` including the OCI manifest type, the metadata path is healthy and my diagnosis is wrong. If it errors, that error is the root cause.
- **§8** — curl from inside the `harbor-core` pod to the registered endpoint, once with TLS verification and once without. Same pod, same network path, same trust store Harbor uses. This separates trust from reachability from auth in two lines.
- **§10** — greps harbor-core for `api controller: get project scanner`, which is where the real error is logged before it gets flattened into the mime message.

There is one command in §8c I deliberately left for you to run by hand, so the password never lands in a log file:

```bash
oc -n <harbor-ns> exec -it <core-pod> -- curl -sSk -u '<user>:<pass>' '<registered-endpoint>/api/v1/metadata'
```

## Questions the commands can't answer

**Registration**
1. Paste the Endpoint field **verbatim** as it appears in Harbor's scanner edit dialog — including or excluding `/endpoint`, port, trailing slash.
2. Authorization type selected, and is "Skip certificate verification" ticked?
3. Is "Use internal registry address" ticked?

**Sequence — this matters more than it looks**
4. In what order did you: add the CA to the bundle → restart Harbor → register the scanner → run the failing scan? Specifically, did the **adapter pod** restart at any point *after* the scanner was registered?
5. How many `harbor-core` replicas do you run, and were **all** of them restarted after the CA configmap change — or just some?
6. Did anything restart the NeuVector controller or scanner pods between the successful registration and the failed scan?

**The scan itself**
7. Was the failing scan triggered manually from the artifact page, from "Scan All", or by scan-on-push?
8. At the moment the scan failed, what did Health show for `neuvector-qa` in Interrogation Services — Healthy or Unhealthy? (Refresh the page immediately after a failed scan; the 30s metadata cache means a stale reading otherwise.)
9. Does it fail on **every** artifact, or only some? If you have a plain single-arch Docker-manifest image (`application/vnd.docker.distribution.manifest.v2+json` rather than OCI), does that one behave differently?
10. Is the failure consistent, or does it succeed occasionally? (Intermittent points hard at multiple core replicas.)

**Trivy comparison**
11. Confirm Trivy scanned the *same digest*, not just the same tag.
12. Is NeuVector set as the **default** scanner, or selected per-project? Which project did the failing scan run in?

**Environment**
13. Harbor version.
14. Are you on the in-cluster Service URL or the Route for this test?
15. Has `harbor-jobservice` also been restarted since the CA change? (The error you pasted comes from core, but jobservice runs the actual scan job, so it needs trust too — a failure there looks different but you'll hit it next.)

## One thing worth doing before you run any of this

If §6b comes back with a TLS error, the fix and the diagnosis are the same action: switch the adapter to the org-signed cert and the Route, since Harbor already trusts your PKI. `dcs.adapter.inClusterCert.enabled: false`, `core.cve.adapter.certificate.secret: dcs-neuvector-external-certs`, adapter Route enabled, Harbor pointed at `https://neuvector-adapter.apps.ocp-qa-hub.x.com/endpoint`.

That removes the CA-injection step, the restart coupling and the ~8-month rotation landmine in one move. If the problem is trust, you'll never see it again; if it isn't, you've lost nothing and eliminated a variable before the next round of debugging.




==========================================





Nearly all 15 are automatable. Rewriting the collector to cover them, with everything variablised:

Rewrote it — 13 of the 15 are now collected automatically, and every name is an override. [scripts/adapter-triage.sh](dcs-neuvector/scripts/adapter-triage.sh), syntax-checked and smoke-tested against a dead cluster so it degrades instead of crashing.

```bash
# required
export HARBOR_NS=harbor
export HARBOR_URL=https://registry.x.com
export SCANNER_NAME=neuvector-qa
read -rs HARBOR_PASS && export HARBOR_PASS

# recommended
export TEST_IMAGE=myproject/myapp:1.2.3     # the artifact that failed

./dcs-neuvector/scripts/adapter-triage.sh > triage-1.txt 2>&1
```

Then run it a second time with `DO_SCAN=1` to reproduce the failure inside the run — the log section at the end picks up the lines it generates:

```bash
DO_SCAN=1 ./dcs-neuvector/scripts/adapter-triage.sh > triage-2.txt 2>&1
```

Send both. Every section is tagged `[Qn]` so the output maps back to the checklist.

## Coverage

| # | question | how |
|---|---|---|
| 1 | Endpoint verbatim | `[Q1]` — dumps the registration object as Harbor stores it |
| 2 | Auth type, skip-cert-verify | `[Q2]` — same dump, all fields |
| 3 | Use internal registry address | `[Q3]` — `use_internal_addr` |
| 4 | Did the adapter restart after registration? | `[Q4]` — registration `update_time` vs pod `startTime`, side by side |
| 5 | How many core replicas, all restarted? | `[Q5]` — count, restart counts, start times, **plus a per-pod probe** |
| 6 | Controller/scanner restarts in between | `[Q6]` — same timeline |
| 7 | How the scan was triggered | `[Q7]` — scan-all schedule; `DO_SCAN=1` reproduces a manual one. **Partial** |
| 8 | Scanner health at failure time | `[Q8]` — the metadata ping plus the `health` field |
| 9 | Every artifact or only some? | `[Q9]` — artifact `type`/`manifest_media_type`, plus the media-type mix across the repo |
| 10 | Consistent or intermittent? | `[Q10]` — N pings via the service, **then one probe from each core pod** |
| 11 | Did Trivy scan the same digest? | `[Q11]` — digest, and `scan_overview` shows which scanner produced each report |
| 12 | Default scanner / project scanner | `[Q12]` — `is_default` and `/projects/{p}/scanner` |
| 13 | Harbor version | `[Q13]` — `/systeminfo` |
| 14 | Service URL or Route? | `[Q14]` — derived from the registered `url` |
| 15 | jobservice restarted? | `[Q15]` — pod start times |

Plus three things not on your list that are worth having: proxy env on core, whether the CA actually landed in core's trust store, and whether the adapter is even listening (the `START` then silence signature).

The **per-pod probe** is the one I'd watch. It execs into every `harbor-core` pod and curls the registered endpoint twice — once verifying TLS, once with `-k`:

- `401` on skip-TLS → reachable, TLS fine, credentials wrong
- `200` on skip-TLS but failure on verify-TLS → trust problem only
- both failing on **one pod only** → that replica is stale, restart it

That single result splits the remaining hypotheses cleanly.

## Overrides

Defaults match the chart; set any that differ:

```
NV_NS=dcs-neuvector                      HARBOR_CORE_SELECTOR=component=core
NV_ADAPTER_DEPLOY=neuvector-registry-adapter-pod
NV_ADAPTER_SVC=neuvector-service-registry-adapter
NV_CONTROLLER_DEPLOY=neuvector-controller-pod
NV_SCANNER_DEPLOY=neuvector-scanner-pod  HARBOR_JOBSVC_SELECTOR=component=jobservice
NV_ADAPTER_AUTH_SECRET=dcs-neuvector-adapter-auth
NV_INTERNAL_CA_SECRET=dcs-neuvector-internal-certs
NV_ADAPTER_CERT_SECRET=<auto-detected>   HARBOR_CORE_DEPLOY=harbor-core
HARBOR_ADMIN=admin                       KUBECTL=oc
PING_COUNT=5   DO_SCAN=0   CURL_OPTS=    # e.g. CURL_OPTS=-k
```

## Still needs your answer

Only two, and both are history the cluster doesn't record:

1. **Q7** — was the failing scan triggered manually from the artifact page, by "Scan All", or by scan-on-push? Past trigger sources aren't recoverable from the API.
2. **Q4, the narrative half** — when did you edit the trusted-CA ConfigMap relative to registering the scanner? The script gets pod and registration timestamps, but a ConfigMap edit leaves no timestamp it can read.

One safety note: credentials are never printed. The adapter secret appears only as a SHA-256 prefix and a length, so you can compare it against what's in Harbor's edit dialog without either value entering the file. Harbor doesn't expose the stored password via API at all — if the fingerprints are the only thing you can't confirm, just re-enter both sides.