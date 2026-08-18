# dcs-neuvector

Wrapper chart around the upstream [`neuvector-helm/charts/core`](https://github.com/neuvector/neuvector-helm/tree/master/charts/core)
`2.11.0` (NeuVector / SUSE Security `5.6.0`), shaped for the NaaS hub-and-spoke
topology, ArgoCD app-of-apps delivery, sealed secrets and airgapped Harbor.

```
dcs-neuvector/
├── Chart.yaml                    core 2.11.0 dependency
├── values.yaml                   defaults + every knob we steer
├── charts/core-2.11.0.tgz        vendored -> no `helm dependency update` in airgap
├── templates/
│   ├── validate.yaml             render-time guardrails (fail fast in ArgoCD)
│   ├── configmap-init.yaml       neuvector-init ConfigMap (sysinitcfg.yaml)
│   ├── sealedsecrets.yaml        all credentials, map-driven
│   ├── certificate-adapter.yaml  in-cluster TLS for the Harbor adapter
│   └── _helpers.tpl
├── docs/initcfg/                 full field reference for every *initcfg.yaml
├── docs/registry-automation.md   registry setup via REST API (no CRD exists)
├── docs/harbor-adapter.md        registering the adapter in Harbor + failure modes
├── envs/                         worked per-environment overlays
└── scripts/
    ├── seal.sh                   produce encryptedData blobs
    └── mirror-images.sh          seed the Harbor mirror
```

## One switch, three roles

`dcs.role` selects the topology; `templates/validate.yaml` refuses to render if
the `core.controller.federation.*` values disagree with it.

| role | where | federation | UI audience |
|---|---|---|---|
| `standalone` | dev | none | admins |
| `hub` | qa-hub, prod-hub | primary, `fed-master` Route | admins only |
| `managed` | qa-managed, prod-managed-* | remote, `fed-managed` Route | tenants + admins |

## OpenShift and vanilla

`core.openshift` is the only other structural switch. On vanilla it swaps Routes
for Ingress and drops the SCC RoleBindings; `validate.yaml` catches the
combinations that cannot work (Route on vanilla, Ingress without a host, TLS
without a secret, no ingress at all). Everything else is identical, including
cert-manager internal certs, sealed secrets, federation and the airgap scanner
flow. See [envs/values-vanilla-managed.yaml](envs/values-vanilla-managed.yaml).

One thing this chart cannot do for you on vanilla: the namespace needs
`pod-security.kubernetes.io/enforce: privileged`, because the enforcer runs
privileged with `hostPID` and PSA rejects it under `baseline`/`restricted`. That
belongs to whatever provisions the namespace.

Federation is joined **declaratively** from `fedinitcfg.yaml` (NeuVector 5.4.0+),
so adding a managed cluster is one sealed secret and one values file — no manual
"generate token in the UI, paste into the remote cluster" step.

## Deploy

```bash
helm template dcs-neuvector . -n dcs-neuvector -f envs/values-qa-hub.yaml
```

ArgoCD application: point at this chart, namespace `dcs-neuvector`, and layer the
cluster's file from `envs/` (or its equivalent in the hub/managed app-of-apps
repo) as the values override.

Package and push to Harbor:

```bash
helm package dcs-neuvector
helm push dcs-neuvector-0.1.0.tgz oci://registry.x.com/helm-oci
```

## Secrets

Nothing plaintext ever enters git. Each credential is a `SealedSecret` whose
`encryptedData` is produced per cluster (each cluster has its own sealed-secrets
key pair, so the same plaintext must be re-sealed for every cluster):

```bash
NS=dcs-neuvector scripts/seal.sh externaltls tls.crt tls.key
NS=dcs-neuvector scripts/seal.sh bootstrap 'S0me-Strong-Pass'
NS=dcs-neuvector scripts/seal.sh pullsecret dockerconfig.json
NS=dcs-neuvector scripts/seal.sh jointoken            # UUID, same on hub + remotes
NS=dcs-neuvector scripts/seal.sh fedinit-primary qa-hub neuvector-fed.apps.ocp-qa-hub.x.com 443 <token>
NS=dcs-neuvector scripts/seal.sh fedinit-remote qa-managed-01 neuvector-fed.apps.ocp-qa-hub.x.com 443 <token> \
                                 neuvector-fed.apps.ocp-qa-mgd01.x.com 443
```

Paste each block under the matching `dcs.secrets.<name>.encryptedData` in the
environment values file. A secret whose `encryptedData` is empty is simply not
rendered, so the chart installs cleanly before every credential exists.

Sealing is strict-scoped — kubeseal's default — so a blob is bound to this exact
namespace and secret name, matching how sealed secrets are made for the other
NaaS components.

| secret | object | contents |
|---|---|---|
| `imagePull` | `dcs-neuvector-registry` | Harbor pull creds |
| `adapterAuth` | `dcs-neuvector-adapter-auth` | basic-auth pair Harbor uses to call the registry adapter (hub only) |
| `externalTls` | `dcs-neuvector-external-certs` | one multi-SAN cert: UI + controller API + fed (+ adapter on hub) |
| `bootstrap` | `neuvector-bootstrap-secret` | initial local `admin` password (name fixed by NeuVector) |
| `init` | `neuvector-init` (name fixed by NeuVector) | `fedinitcfg.yaml` today; `ldap/oidc/roleinitcfg.yaml` next iteration |

## Namespace

`dcs.namespace` declares the target namespace, consistent with the other NaaS
components. It defaults to the release namespace and **must equal it**: the
upstream subchart hardcodes `.Release.Namespace` in its own templates, so a
mismatch would put our SealedSecrets and ConfigMap somewhere NeuVector cannot
read them — with no error at apply time, just a controller that silently ignores
its configuration. `validate.yaml` fails the render instead.

## Labels

Deliberately minimal: `app.kubernetes.io/name`, `app.kubernetes.io/part-of`,
`helm.sh/chart`, `dcs.io/cluster-role`. Two common ones are **not** set here:

- `app.kubernetes.io/instance` — ArgoCD's default `instanceLabelKey`. Setting it
  ourselves risks colliding with application tracking.
- `app.kubernetes.io/managed-by` — only added by the Helm CLI. ArgoCD renders
  with `helm template`, so Helm adds nothing at all and the label would be a lie;
  ArgoCD applies its own tracking label or annotation.

`dcs.commonLabels` / `dcs.commonAnnotations` remain as escape hatches.

## Decisions worth knowing

**`core.autoGenerateCert: false` is mandatory here.** The upstream chart mints a
self-signed cert with `genSelfSignedCert` guarded by a `lookup` of the live
Secret. ArgoCD renders with `helm template`, where `lookup` returns nothing, so a
brand-new cert is generated on every sync — permanent OutOfSync plus a rolling
restart from the `checksum/*-secret` pod annotation. Manager and controller certs
therefore come from the sealed `dcs-neuvector-external-certs` instead. Note this
setting is about the *external* REST/UI certs only — internal component mTLS is a
separate mechanism (`internal.*`, below).

**We own the internal CA, not the subchart.** `core.internal.certmanager.enabled`
is **false**; `dcs.internalCa` creates the Issuer and CA Certificate instead.
Upstream hardcodes a 2-year CA with no `renewBefore`, so cert-manager re-issues it
about every 8 months — and every re-issue invalidates any trust bundle that pinned
it (Harbor's, for one), turning a certificate renewal into a recurring manual task
whose failure mode is a silently empty scan. Ours is 10 years with
`rotationPolicy: Never`, so the key is reused on renewal and previously
distributed copies of the CA keep validating.

**Internal mTLS is still cert-manager**, just ours: a self-signed `Issuer` plus a
CA `Certificate` inside the namespace. It does not use (or need) the org
ClusterIssuer, and it faces no browser. cert-manager was chosen over the built-in
`cert-upgrader` rotation because the `Certificate` CR is declarative in git while
the resulting Secret is not, so ArgoCD sees no drift. Every component's
`internal.certificate.secret` must name `dcs.internalCa.secretName` or the
upstream templates render an empty `secretName` — `validate.yaml` enforces both
that and the "two Certificates fighting over one secret" mistake.

**External certs: one multi-SAN cert per cluster.** Route termination is
`passthrough`, so the pod serves the cert directly and every SAN must equal its
Route host exactly. Wildcards are not permitted by org policy, so each cluster
gets one 4096-bit cert whose SAN list covers the UI, the controller REST API and
the federation endpoint — including hostnames whose Route is disabled today,
because adding a SAN now is free while re-issuing across deployed environments is
not. Secret `dcs-neuvector-external-certs`, referenced by both the manager and
the controller. See `../csr/`.

Federation does not rely on this cert. `controller/rest/federation.go` sends all
federation REST traffic through a client with `InsecureSkipVerify: true` and
establishes its own mTLS from the CA/client certificates exchanged during the
join, so adding a cluster to the federation costs zero CSRs.

**Passthrough Routes answer on :443.** The federation peer dials the router, not
the Service, so `Primary_Rest_Info.Port` / `Managed_Rest_Info.Port` in
`fedinitcfg.yaml` is `443` — not `11443` / `10443`.

**The CVE database lives inside the scanner image.** The `updater` CronJob
downloads nothing; it `PATCH`es the scanner Deployment with a `restartedAt`
annotation so the pods re-pull. Airgap flow:

```
docker.io/neuvector/scanner:6  --replication 02:00-->  internet Harbor
                               --replication 02:00-->  airgap Harbor
updater CronJob 03:00 -> scanner pods restart -> re-pull -> fresh CVE DB
```

`imagePullPolicy: Always` on the scanner is therefore load-bearing;
`validate.yaml` blocks changing it while the updater is enabled.

**`core.imagePullSecrets` is a single string**, not a list — upstream contract.

**Service account names are upstream's, on purpose.** `leastPrivilege: true`
makes the chart create seven SAs with fixed names (`basic`, `controller`,
`enforcer`, `scanner`, `updater`, `registry-adapter`, `cert-upgrader`) and
ignores `core.serviceAccount`. Renaming them to `dcs-neuvector-sa` would mean
`leastPrivilege: false`, collapsing every component onto one identity — and the
privileged SCC would then apply to the UI and scanner pods too. The names are
namespace-scoped inside `dcs-neuvector`, so they collide with nothing; the
security boundary is worth more than the naming convention here.

Two other names are fixed by NeuVector itself and cannot be prefixed:
`neuvector-init` (projected by name into the controller) and
`neuvector-bootstrap-secret` (read by name through the API).

**SCC is upstream's job, not ours.** With `openshift: true` *and*
`leastPrivilege: true` the subchart already emits the right wiring:
a `system:openshift:scc:privileged` RoleBinding for the **enforcer SA only**, and
a purpose-built restrictive SCC `neuvector-scc-controller` (no privileged, no
hostPID, `RunAsAny` uid) bound to the controller SA. Everything else runs under
the default `restricted-v2`.

This chart previously added its own bindings granting `anyuid` more broadly —
that was removed, because it was both redundant and weaker than what upstream
already does. If you ever set `leastPrivilege: false`, none of this is generated
and you are back to needing manual `oc adm policy add-scc-to-user`.

**`neuvector-init` is owned by this chart**, split across a plain ConfigMap
(`sysinitcfg.yaml`, no secrets, diffable in git) and a SealedSecret (everything
with a credential in it). A filename may live in exactly one of the two — the
controller merges them through a projected volume and duplicate paths make the
pod fail to start.

**`always_reload: true`** means git wins: `sysinitcfg.yaml` is re-applied on every
controller restart, reverting manual UI drift. That is the intent under GitOps;
set `dcs.systemConfig.alwaysReload: false` if you ever need the UI to be
authoritative.

## Prepared for the next iteration

Wired but off, so enabling is a values-only change:

- `dcs.systemConfig.modeAuto.*` — timed Discover → Monitor → Protect migration.
- `dcs.systemConfig.scannerAutoscale` — controller-driven scanner scaling.
- `dcs.secrets.init` — add `ldapinitcfg.yaml` (admin AD), `oidcinitcfg.yaml`
  (Keycloak + group→namespace role mapping) and `roleinitcfg.yaml` (custom
  tenant role) as further sealed keys.
- `core.cve.adapter.enabled` — Harbor pluggable-scanner adapter, hub only.
  Replaces Trivy so Harbor no longer needs internet access for a CVE database:
  Harbor calls the adapter over in-cluster Service DNS
  (`https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/endpoint`),
  authenticating with the basic-auth pair from `dcs.secrets.adapterAuth`, and
  verifying the cert issued for those DNS names by
  `templates/certificate-adapter.yaml`.
- `dcs.extraSecrets` — e.g. the Harbor robot credential for registry scanning.
