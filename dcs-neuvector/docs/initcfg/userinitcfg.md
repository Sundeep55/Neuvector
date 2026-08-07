# `userinitcfg.yaml` — local users

Creates local NeuVector accounts, and can overwrite the built-in `admin`.
Contains passwords → **SealedSecret** only.

**We do not use this file.** The initial admin password comes from the
`neuvector-bootstrap-secret` Secret instead, which is simpler (one key, no YAML)
and is the mechanism the upstream chart itself uses. Documented because it is the
only way to declare *additional* local accounts, which is occasionally the right
answer for break-glass.

## Fields

| field | required | values | meaning |
|---|---|---|---|
| `always_reload` | optional | bool | Re-apply on every controller start. Careful: with `true`, a password changed in the UI is reset to the file's value on the next restart. |
| `users[]` | — | list | One entry per account. |
| `users[].Fullname` | **required** | `^[a-zA-Z0-9]+[.:a-zA-Z0-9_-]*$` | The username. Despite the name, this is the login identifier. |
| `users[].Password` | optional | string | Minimum 6 characters; must not start with any of ``] ` } * | < > ! %``. Also subject to [passwordprofileinitcfg.md](passwordprofileinitcfg.md). |
| `users[].EMail` | optional | string | Contact address. |
| `users[].Role` | optional | `admin` \| `reader` \| `""` | Global role. `""` means no cluster-wide rights — pair with `Role_Domains`. |
| `users[].Role_Domains` | optional | map | Role → list of namespaces, same shape as `role_domains` in the auth files. Lets a local account be namespace-scoped. |
| `users[].Locale` | optional | `en` \| `zh_cn` | UI language. Default `en`. |
| `users[].Timeout` | optional | int `30`–`3600` | Session idle timeout in seconds. Default `300`. |

## Overwriting the built-in admin

An entry with `Fullname: admin` replaces the default account:

```yaml
users:
  - Fullname: admin
    Password: <sealed>
    Role: admin
```

Known upstream behaviour worth planning around: if the admin password has already
been changed once, a later ConfigMap/Secret change may not overwrite it
(neuvector/neuvector issue #1389). Do not rely on this file to rotate the admin
password on an established cluster — rotate it through the UI or the API.

## Why `neuvector-bootstrap-secret` is preferred

The controller reads a Secret named exactly `neuvector-bootstrap-secret` with a
single key `bootstrapPassword`, and applies it as the initial `admin` password.
It is read through the API rather than mounted, which is why the name is fixed
and cannot be prefixed with `dcs-`. Our chart creates it as a SealedSecret:

```bash
scripts/seal.sh bootstrap 'S0me-Strong-Pass'
```

Keep that account working even after SSO lands: an OIDC/LDAP admin **cannot**
promote a cluster to federation primary, so a local admin is the break-glass
identity for that operation.
