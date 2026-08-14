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