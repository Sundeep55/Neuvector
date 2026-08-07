# `passwordprofileinitcfg.yaml` — password policy

Applies to **local** NeuVector accounts only. LDAP and OIDC users are governed by
the directory / Keycloak policy, so this file protects the local `admin` and any
break-glass account.

No credentials → plain ConfigMap is fine.

Recommended once the platform is real: the default minimum length of 6 is well
below most corporate baselines, and lockout is off by default.

## Fields

Only the profile named `default` is supported — upstream: "only default profile
is supported".

| field | values | default | meaning |
|---|---|---|---|
| `always_reload` | bool | `false` | Re-apply on every controller start. |
| `active_profile_name` | string | `default` | Which profile is in force. Leave as `default`. |
| `pwd_profiles[].name` | string | `default` | Profile name. Must be `default`. |
| `pwd_profiles[].comment` | string | — | Free text. |
| `pwd_profiles[].min_len` | int | `6` | Minimum password length. |
| `pwd_profiles[].min_uppercase_count` | int | `0` | Required uppercase characters. |
| `pwd_profiles[].min_lowercase_count` | int | `0` | Required lowercase characters. |
| `pwd_profiles[].min_digit_count` | int | `0` | Required digits. |
| `pwd_profiles[].min_special_count` | int | `0` | Required special characters. |
| `pwd_profiles[].enable_block_after_failed_login` | bool | `false` | Enable lockout after repeated failures. |
| `pwd_profiles[].block_after_failed_login_count` | int | `0` | Failures before lockout. Only read when the flag above is `true`. |
| `pwd_profiles[].block_minutes` | int | `0` | Lockout duration in minutes. |
| `pwd_profiles[].enable_password_expiration` | bool | `false` | Enable password ageing. |
| `pwd_profiles[].password_expire_after_days` | int | `0` | Maximum password age in days. |
| `pwd_profiles[].enable_password_history` | bool | `false` | Prevent reuse of recent passwords. |
| `pwd_profiles[].password_keep_history_count` | int | `0` | How many previous passwords to remember. |
| `pwd_profiles[].session_timeout` | int `30`–`3600` | `300` | Idle session timeout in seconds, applied platform-wide. |

## Suggested baseline

```yaml
always_reload: true
active_profile_name: default
pwd_profiles:
  - name: default
    comment: DCS NaaS baseline
    min_len: 16
    min_uppercase_count: 1
    min_lowercase_count: 1
    min_digit_count: 1
    min_special_count: 1
    enable_block_after_failed_login: true
    block_after_failed_login_count: 5
    block_minutes: 15
    enable_password_history: true
    password_keep_history_count: 5
    enable_password_expiration: false
    session_timeout: 900
```

Two deliberate choices there. Password expiry is left off: for a break-glass
account rotated by sealed secret, forced ageing produces lockouts at exactly the
wrong moment. And `session_timeout: 900` is a compromise — long enough to work
through an investigation, short enough for a shared admin console.

Check `min_len` against whatever `scripts/seal.sh bootstrap` was given: a
bootstrap password shorter than the profile minimum is a confusing first-login
failure.
