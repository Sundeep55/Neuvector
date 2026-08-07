# NeuVector declarative configuration (`*initcfg.yaml`) — reference

NeuVector 5.x can be configured entirely from files that the controller reads at
startup. This is what makes the whole platform GitOps-able: no click-ops, no
`curl` bootstrap, no snowflake clusters.

These pages document **every field** of every file, so nobody has to reverse
engineer the upstream sample later.

| file | what it configures | secret? | used today |
|---|---|---|---|
| [sysinitcfg.md](sysinitcfg.md) | system settings: policy mode, cluster name, syslog, proxies, scanner autoscale, mode automation | no | **yes** |
| [fedinitcfg.md](fedinitcfg.md) | federation: promote to primary / auto-join as remote | **yes** (join token) | **yes** |
| [roleinitcfg.md](roleinitcfg.md) | custom roles and their per-resource permissions | no | next iteration |
| [ldapinitcfg.md](ldapinitcfg.md) | LDAP / Active Directory auth + group→role mapping | **yes** (bind password) | next iteration |
| [oidcinitcfg.md](oidcinitcfg.md) | OIDC (Keycloak) auth + group→role→namespace mapping | **yes** (client secret) | next iteration |
| [samlinitcfg.md](samlinitcfg.md) | SAML auth + group→role mapping | **yes** | not planned |
| [userinitcfg.md](userinitcfg.md) | local users, including overriding the built-in `admin` | **yes** (passwords) | no — we use `neuvector-bootstrap-secret` |
| [passwordprofileinitcfg.md](passwordprofileinitcfg.md) | password complexity, lockout, expiry, session timeout | no | recommended |
| [eulainitcfg.md](eulainitcfg.md) | SUSE Security licence key | **yes** | no — we run the open-source build |

## How the controller loads them

The controller mounts a **projected volume** at `/etc/config` from three optional
sources (see `controller-deployment.yaml` in the upstream chart):

```
configMap  neuvector-init      (optional)
secret     neuvector-init      (optional)
secret     neuvector-secret    (optional)
```

In this chart, `configmap-init.yaml` owns the ConfigMap and
`sealedsecrets.yaml` owns the Secret; the upstream chart's own generators
(`core.controller.configmap.enabled` / `core.controller.secret.enabled`) are
forced off by `validate.yaml`.

### Trap 1 — a filename may live in exactly one source

A projected volume cannot merge two sources that contain the same path. If
`sysinitcfg.yaml` exists in both the ConfigMap and the Secret, the **controller
pod fails to start**. Split by sensitivity, never duplicate:

- no credentials in it → ConfigMap (diffable in git, reviewable in a PR)
- any credential in it → SealedSecret

### Trap 2 — Secret entries drop the `|`

In a ConfigMap each file is a literal block scalar (`sysinitcfg.yaml: |`). When
the same content goes into a Secret it is the secret *value*, so the pipe is
removed. Our `scripts/seal.sh` builds real files and runs `kubeseal` on them, so
this only matters if you hand-write a Secret.

### Trap 3 — `always_reload`

Without it, a file is applied only when a **new** cluster is created or the whole
cluster restarts — not on a rolling upgrade, and not when you change the
ConfigMap. Add `always_reload: true` (4.3.2+) to any file that git should own,
and the controller re-applies it on every start.

The consequence is deliberate: **git wins, the UI loses**. Anything an admin
changes in the console that is also expressed in an `always_reload: true` file is
reverted at the next controller restart. That is what we want for a
GitOps-managed platform, but it must be understood before someone "fixes"
something in the UI and watches it disappear.

### Trap 4 — precedence against persistent storage

With `controller.pvc.enabled: true` the controller restores its configuration
backup from the PVC first, **then** applies the initcfg files on top. So the
files take precedence over restored state. Upstream also documents that the
files are read on new-cluster deploy or full restart rather than during a rolling
upgrade; `always_reload: true` is what makes them re-apply on an ordinary
controller restart. Worth confirming the exact interaction in dev before relying
on it for a live config change.

## Applying a change

1. Edit the values in the environment file (`dcs.systemConfig.*`) or re-seal the
   secret file (`scripts/seal.sh`).
2. Commit; ArgoCD syncs the ConfigMap / SealedSecret.
3. Restart the controllers so the file is re-read:
   `oc -n dcs-neuvector rollout restart deploy/neuvector-controller-pod`
4. Confirm: `oc -n dcs-neuvector logs deploy/neuvector-controller-pod | grep -i initcfg`

A ConfigMap change alone does **not** reconfigure a running controller.

## Source

Fields below are taken from the upstream complete sample, cross-checked against
the chart templates and the controller source where behaviour was ambiguous:

- <https://open-docs.neuvector.com/deploying/production/configmap/>
- <https://documentation.suse.com/cloudnative/security/5.5/en/configmap.html>

Where the upstream documentation is silent or self-contradictory, the page says
so explicitly instead of guessing.
