# Automating registry configuration

**Short answer: yes, fully — but only through the REST API.**

Registries are the one part of NeuVector that has no declarative path. Verified
against 5.6:

- **No CRD.** The chart ships nine CRDs (`nvsecurityrules`,
  `nvclustersecurityrules`, `nvdlpsecurityrules`,
  `nvadmissioncontrolsecurityrules`, `nvwafsecurityrules`,
  `nvcomplianceprofiles`, `nvvulnerabilityprofiles`, `nvgroupdefinitions`,
  `nvresponserulesecurityrules`). None of them describes a registry.
- **No initcfg file.** The eight `*initcfg.yaml` files cover system, federation,
  auth, roles, users and password policy — see [docs/initcfg/](initcfg/).
- **A complete REST API**, listed below.

So registry setup is automatable, it just belongs in a Job rather than in a
manifest. That is a good fit for your ArgoCD flow: a post-sync hook Job in the
per-namespace child chart, using the same pattern proposed for the group→role
mapping.

## Endpoints

From `controller/rest/rest.go`:

| method | path | purpose |
|---|---|---|
| `POST` | `/v1/auth` | Log in, obtain a token |
| `DELETE` | `/v1/auth` | Log out |
| `POST` | `/v1/scan/registry` · `/v2/scan/registry` | Create a registry |
| `PATCH` | `/v1/scan/registry/{name}` · `/v2/...` | Update a registry |
| `GET` | `/v1/scan/registry` | List (`?scope=` `""`\|`fed`\|`local`) |
| `GET` | `/v1/scan/registry/{name}` | Show one |
| `DELETE` | `/v1/scan/registry/{name}` | Delete |
| `POST` | `/v1/scan/registry/{name}/scan` | Start a scan now |
| `DELETE` | `/v1/scan/registry/{name}/scan` | Stop a running scan |
| `POST` | `/v1/scan/registry/{name}/test` | Test connectivity (debug) |
| `GET` | `/v1/scan/registry/{name}/images` | Image summary |
| `GET` | `/v1/scan/registry/{name}/image/{id}` | Per-image scan report |
| `GET` | `/v1/scan/registry/{name}/layers/{id}` | Per-layer report |

The last three are what a tenant self-service report export would build on.

## Authentication

```bash
TOKEN=$(curl -sk -X POST https://$NV_API/v1/auth \
  -H 'Content-Type: application/json' \
  -d '{"password":{"username":"admin","password":"'"$NV_PASS"'"}}' \
  | jq -r .token.token)
```

Every subsequent call carries `X-Auth-Token: $TOKEN`
(`api.RESTTokenHeader = "X-Auth-Token"`). Log out when done — tokens are
sessions, and a Job that leaks one per run will pile them up.

In-cluster the API is `https://neuvector-svc-controller-api.dcs-neuvector.svc:10443`,
so a Job needs no external Route.

## Payload

`RESTRegistryConfig` (v1). All pointer fields are optional; omitted means
"leave unchanged" on `PATCH`.

| field | json | notes |
|---|---|---|
| Name | `name` | Unique identifier; also the URL segment for later calls. |
| Type | `registry_type` | `Harbor` for us. Also Docker, JFrog, Quay, ECR, GCR, ACR, Nexus, GitLab, OpenShift, IBM Cloud, GitHub. |
| Registry | `registry` | Base URL, e.g. `https://registry.x.com`. |
| **Domains** | `domains` | **List of namespaces this registry is scoped to.** The multi-tenancy lever — see below. |
| Filters | `filters` | Repository/tag patterns. At least one is required; blank is rejected. `project/*:*`, `alpine:3.[8\|9].*`, regex. |
| Username / Password | `username` / `password` | Harbor robot credentials. |
| AuthToken / AuthWithToken | `auth_token` / `auth_with_token` | Token auth instead of basic. |
| RescanImage | `rescan_after_db_update` | Re-scan everything when the CVE DB changes. Powerful, and expensive at 800-namespace scale — think before enabling globally. |
| ScanLayers | `scan_layers` | Produce per-layer results. |
| RepoLimit / TagLimit | `repo_limit` / `tag_limit` | Caps per crawl. Useful guardrails on a large Harbor. |
| Schedule | `schedule` | `{"schedule":"...","interval":<seconds>}` — periodic scanning, 5 minutes to 7 days. |
| CfgType | `cfg_type` | `user_created` (local) or `federal` (hub-wide, see below). `ground` is CRD-sourced config. |
| IgnoreProxy | `ignore_proxy` | Bypass the configured registry proxy. |

The `/v2` variant takes the same data grouped into `auth`, `scan` and
`integrations` sub-objects; either works.

## The `domains` field is the tenant boundary

Upstream: *"When a namespace restricted user configures a registry in Assets,
only users with access to that namespace can see/scan that registry. Global users
will be able to see/manage that registry, but not any users with restricted
namespaces/role."*

`domains` lets an **admin** create that same namespace-scoped registry directly,
which is what makes onboarding automatable. One registry entry per tenant
namespace, pointing at the same Harbor but filtered to that tenant's project:

```json
{
  "config": {
    "name": "harbor-alpha-app-a1b2",
    "registry_type": "Harbor",
    "registry": "https://registry.x.com",
    "domains": ["alpha-app-a1b2"],
    "filters": ["alpha-app-a1b2/*:*"],
    "username": "robot$dcs-neuvector-scanner",
    "password": "<from sealed secret>",
    "rescan_after_db_update": false,
    "scan_layers": true,
    "cfg_type": "user_created",
    "schedule": {"schedule": "", "interval": 86400}
  }
}
```

Two boundaries hold this together, and both matter: `domains` controls **who can
see the entry**, `filters` controls **what gets crawled**. Set both. A tenant
entry with the right `domains` but a `*/*` filter would crawl every project in
Harbor and surface it to that tenant.

## Federated registries (hub)

With `cfg_type: "federal"` on the hub, plus `Deploy_Repo_Scan_Data: true` in
[fedinitcfg.yaml](initcfg/fedinitcfg.md), a registry is scanned **once on the
hub** and the results replicate to every managed cluster. At your scale that is
the difference between crawling Harbor once and crawling it once per cluster.

Unverified: whether `domains` scoping survives replication to the remote
clusters. Upstream does not say, and it decides whether tenant-scoped entries can
be federal or must be per-cluster `user_created`. Worth testing in QA once the
hub and one managed cluster are federated — it is a 15-minute test with a real
answer, and it changes the onboarding design.

## Harbor robot permissions

One **system-level** robot, read-only, never shared with tenants:

- list projects, list repositories, list artifacts/tags
- **pull** (the scanner downloads and unpacks the image)

No push, no delete, no project administration. Store it as
`dcs.extraSecrets.harborRobot` (keys `username`, `password`) and mount it into
the Job.

## Idempotency

`POST` on an existing name fails. Make the Job re-runnable — ArgoCD will run it
again — by treating "exists" as "update":

```bash
if curl -sk -o /dev/null -w '%{http_code}' -H "X-Auth-Token: $TOKEN" \
     "https://$NV_API/v1/scan/registry/$NAME" | grep -q 200; then
  curl -sk -X PATCH -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
    "https://$NV_API/v1/scan/registry/$NAME" -d "$PAYLOAD"
else
  curl -sk -X POST  -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
    "https://$NV_API/v1/scan/registry" -d "$PAYLOAD"
fi
```

## Where to put the Job

**Platform-level (now):** one Job in this chart or the app-of-apps that registers
the single Harbor registry for admin visibility. No tenant scoping, no per-tenant
churn.

**Per-tenant (onboarding iteration):** a post-sync hook Job in the existing
per-namespace child chart. It already knows the namespace name with its
4-character suffix and the Harbor project, which is exactly the input this API
needs — the same Job can add the `group_mapped_roles` entry via
`PATCH /v1/server/{name}`. That keeps onboarding in one place and avoids
regenerating a single 800-entry YAML file on every request.

## Alternative: don't use NeuVector registries for tenants at all

The Harbor pluggable-scanner adapter puts scan results in the **Harbor** UI under
Harbor's own project RBAC, which already encodes the tenant boundary you built.
Then NeuVector registry entries exist only for the platform team, and there is no
per-tenant NeuVector registry object to create, scope or clean up on offboarding.

The two are not exclusive: the adapter gives tenants results where their images
already live, `domains`-scoped entries give them results in NeuVector next to
their runtime findings. Deciding which is the *primary* surface is worth doing
before onboarding automation is written, because it determines how much per-tenant
state NeuVector has to hold.
