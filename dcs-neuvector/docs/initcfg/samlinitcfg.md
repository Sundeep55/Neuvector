# `samlinitcfg.yaml` — SAML authentication

Not planned for this platform (Keycloak fronts the org IDP over SAML already, and
NeuVector talks to Keycloak over OIDC). Documented so the option is understood
rather than rediscovered.

Carries no password, but it does carry IdP certificates and is grouped with the
other auth files → keep it in the **SealedSecret** `neuvector-init`.

## Fields

| field | required | values | meaning |
|---|---|---|---|
| `always_reload` | optional | bool | Re-apply on every controller start. |
| `SSO_URL` | **required** | URL | IdP single sign-on endpoint NeuVector redirects users to. |
| `Issuer` | **required** | URL | IdP entity ID / issuer. |
| `X509_Cert` | **required** | PEM block | IdP signing certificate used to validate assertions. |
| `x509_cert_extra` | optional | list of PEM blocks | Additional signing certificates. Use during an IdP certificate rollover so both the old and new signer are accepted. |
| `Group_Claim` | optional | string | SAML attribute carrying group membership. |
| `Enable` | optional | bool | Turns the auth server on. |
| `Default_Role` | optional | `admin` \| `reader` \| `""` | Role for an authenticated user matching no group mapping. Use `""`. |
| `group_mapped_roles` | optional | list | Identical structure and semantics to the OIDC version — see [oidcinitcfg.md](oidcinitcfg.md#group_mapped_roles), including **first match wins** ordering. |

## Why we chose OIDC instead

Both reach the same identity provider through Keycloak. OIDC wins on three
practical points:

- Client registration is per cluster and self-contained: one confidential client,
  one redirect URI, one secret. No metadata exchange, no per-cluster SP entity.
- Certificate rollover is Keycloak's problem, not a `X509_Cert` field that has to
  be re-sealed in every environment when the IdP rotates its signer.
- The group claim is a Keycloak mapper we control, rather than an assertion
  attribute negotiated with the IdP team.

If SAML ever becomes necessary, the role and namespace mapping semantics are
identical, so [roleinitcfg.md](roleinitcfg.md) applies unchanged.
