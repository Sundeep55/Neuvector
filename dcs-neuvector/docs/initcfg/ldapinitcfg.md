# `ldapinitcfg.yaml` — LDAP / Active Directory authentication

Carries the bind password → always in the **SealedSecret** `neuvector-init`.

This is the admin authentication path on **every** cluster, hub and managed
alike: admins sign in with their AD account, tenants (on managed clusters only)
sign in through OIDC.

## Fields

| field | required | values | meaning |
|---|---|---|---|
| `always_reload` | optional | bool | Re-apply on every controller start. |
| `directory` | **required** | `OpenLDAP` \| `MicrosoftAD` | Selects the schema defaults for the two attribute fields below. |
| `Hostname` | **required** | string | LDAP server host. |
| `Port` | optional | int | Default `389`. Use `636` with `SSL: true`. |
| `SSL` | optional | bool | LDAPS. Default `false` — do not leave it off in production. |
| `base_dn` | **required** | DN | Search base for users/groups. Note the upstream sample shows `cn=admin,dc=example,dc=org` here and `dc=example,dc=org` in `bind_dn`, which is the reverse of the usual convention; treat the sample as illustrative and confirm against your directory. |
| `bind_dn` | optional | DN | Service account used to search. Omit only for anonymous bind. |
| `bind_password` | optional | string | Password for `bind_dn`. **The reason this file is sealed.** |
| `group_member_attr` | optional | string | Attribute listing group membership. Empty → `memberUid` for OpenLDAP, `member` for AD. |
| `username_attr` | optional | string | Attribute holding the login name. Empty → `cn` for OpenLDAP, `sAMAccountName` for AD. |
| `Enable` | optional | bool | Turns the auth server on. |
| `Default_Role` | optional | `admin` \| `reader` \| `""` | Role for an authenticated user matching no group mapping. Set `""` so directory membership is what actually grants access. |
| `group_mapped_roles` | optional | list | Identical structure and semantics to the OIDC version — see [oidcinitcfg.md](oidcinitcfg.md#group_mapped_roles), including **first match wins** ordering. |

## Example — admin access on the hub

```yaml
always_reload: true
directory: MicrosoftAD
Hostname: ldaps.x.com
Port: 636
SSL: true
base_dn: dc=x,dc=com
bind_dn: cn=svc-neuvector,ou=service-accounts,dc=x,dc=com
bind_password: <sealed>
username_attr: sAMAccountName
group_member_attr: member
Enable: true
Default_Role: ""
group_mapped_roles:
  - group: DCS-Platform-Admins
    global_role: admin
  - group: DCS-Platform-Readers
    global_role: reader
```

## Coexistence with OIDC

LDAP and OIDC can be configured at the same time; they are separate auth servers.
LDAP users authenticate through the normal username/password form, while OIDC
appears as a separate SSO entry point on the login page. On managed clusters both
are active — admins via AD, tenants via Keycloak. Worth a quick confirmation of
the login-page behaviour in dev, since it is the first thing every user sees.

## Certificate trust

`SSL: true` against an internal CA raises the same trust question as OIDC: the
controller needs that CA in `/etc/ssl/certs/ca-certificates.crt`, and the chart
has no value for it. See the "private CA trust" section in
[oidcinitcfg.md](oidcinitcfg.md). Solve it once and both auth paths benefit.
