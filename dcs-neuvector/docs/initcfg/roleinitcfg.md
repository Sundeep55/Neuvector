# `roleinitcfg.yaml` — custom roles

Defines roles beyond the built-in `admin`, `reader` and `ciops`. This is the file
that decides **what a tenant can actually do inside their namespace**, so it is
the centre of the multi-tenancy design.

No credentials, so it can live in the plain ConfigMap — but it is referenced by
`ldapinitcfg.yaml` / `oidcinitcfg.yaml`, which do carry credentials. Keep the
role definitions in the ConfigMap and the mappings in the Secret.

## Structure

```yaml
always_reload: false
roles:
  - Name: testrole            # mandatory, ^[a-zA-Z0-9]+[.:a-zA-Z0-9_-]*$
    Comment: test role        # optional
    Permissions:              # mandatory
      - id: rt_scan
        read: true
        write: true
```

A permission entry omits `read` or `write` to leave it unset (denied). Listing
an `id` with neither is equivalent to not listing it.

## Permission IDs

| id | read grants | write grants |
|---|---|---|
| `config` | View system configuration | Change system configuration, registries, scanners, federation. **The key to withhold from tenants** — CVE exception/vulnerability-profile management sits behind it. |
| `rt_scan` | View runtime workload scan results and vulnerabilities | Trigger scans of running workloads |
| `reg_scan` | View registry scan results | Configure registries and trigger registry scans |
| `ci_scan` | — | Submit CI/CD build scans (write-only permission; used by pipeline tokens) |
| `rt_policy` | View network rules, process/file profiles, groups, DLP/WAF | Edit those rules and profiles |
| `admctrl` | View admission control rules | Edit admission control rules |
| `compliance` | View compliance/benchmark results and profiles | Edit compliance profiles |
| `audit_events` | View audit events (scan/compliance findings) | — |
| `security_events` | View security events (runtime violations) | — |
| `events` | View system/notification events | — |
| `authentication` | View auth server config (LDAP/OIDC/SAML) | Edit auth server config |
| `authorization` | View users, roles, role mappings | Edit users, roles, role mappings |

## Built-in roles for comparison

| role | scope | summary |
|---|---|---|
| `admin` | global or per-namespace | Everything within scope. |
| `reader` | global or per-namespace | Read-only across resources within scope. |
| `ciops` | global or per-namespace | Aimed at pipelines: scan submission and results, no policy editing. |
| *(none)* | — | Assign `global_role:` empty with `role_domains` to give a user access **only** to named namespaces and nothing globally. This is the tenant shape. |

## Proposed tenant role

Matches the stated requirement — tenants can do what makes sense inside their own
namespace, but cannot grant themselves CVE exceptions:

```yaml
always_reload: true
roles:
  - Name: dcstenant
    Comment: NaaS tenant - full visibility and policy control within own namespaces
    Permissions:
      - id: rt_scan
        read: true
        write: true          # may rescan their own workloads
      - id: reg_scan
        read: true           # sees their Harbor project scan results
      - id: rt_policy
        read: true
        write: true          # owns network rules / process profiles for their namespace
      - id: admctrl
        read: true           # sees admission decisions affecting them, cannot change them
      - id: compliance
        read: true
      - id: audit_events
        read: true
      - id: security_events
        read: true
      - id: events
        read: true
      # deliberately absent:
      #   config        -> blocks CVE exceptions / vulnerability profiles / registry config
      #   ci_scan       -> add later if tenants need pipeline scan submission
      #   authentication, authorization -> platform-team only
```

Assign it per namespace through `role_domains` in
[oidcinitcfg.md](oidcinitcfg.md) / [ldapinitcfg.md](ldapinitcfg.md):

```yaml
group_mapped_roles:
  - group: <tenant-group>
    global_role: ""            # nothing globally
    role_domains:
      dcstenant:
        - <namespace-with-suffix>
```

## Open question for the CVE-exception design

Withholding `config: write` blocks tenants from creating vulnerability profiles
in the UI. It does **not** by itself give them a way to *request* an exception —
that workflow (request → platform review → apply) has no native equivalent, which
is why it was scoped as a later custom layer. Two building blocks exist:

- `NvVulnerabilityProfile` CRDs, so accepted exceptions are declarative and
  reviewable in git rather than clicked in the console.
- Per-cluster, per-group role variants (e.g. `dcstenant` vs `dcstenant-cve`), so
  the capability can be granted to specific tenants without changing the default.

Worth confirming in dev whether a profile created by CRD is visible-but-immutable
to a namespace user, or invisible — that determines whether tenants can at least
*see* which exceptions apply to them.
