# `sysinitcfg.yaml` — system configuration

Everything under **Settings → Configuration** in the console. No credentials
except the registry-proxy password, so in this chart it lives in the plain
ConfigMap `neuvector-init`, generated from `dcs.systemConfig.*` by
`templates/_helpers.tpl`.

Field names are `Capitalised_With_Underscores`. Our values file uses camelCase
purely as a friendlier input surface — the helper translates. Verify any time
with `helm template ... | grep -A25 sysinitcfg`.

## General

| field | values | default | meaning |
|---|---|---|---|
| `always_reload` | bool | `false` | Re-apply this file on every controller start. We set `true`: git owns the config. |
| `Cluster_Name` | string | `cluster.local` | Identity of this cluster, shown in the federation switcher on the hub. Must be unique per environment. `fedinitcfg.yaml`'s `Cluster_Name` overrides this one. Chart value: `dcs.clusterName`. |
| `No_Telemetry_Report` | bool | `false` | Stop sending usage telemetry. **Set `true` on every airgapped cluster** — otherwise the controller repeatedly attempts an outbound call that cannot succeed. |
| `Unused_Group_Aging` | int `0`–`168` | `24` | Hours before a group with no members is aged out. `0` disables aging. |
| `Xff_Enabled` | bool | `true` | Trust `X-Forwarded-For` when attributing source IPs. Correct for us: traffic arrives via the OpenShift router. |
| `Monitor_Service_Mesh` | bool | `true` | Inspect Istio/Linkerd sidecar traffic. We set `false` — no mesh, and it costs enforcer work. |
| `Controller_Debug` | list of `cpath`, `mutex`, `conn`, `scan`, `cluster` | empty | Debug logging categories. Support use only; noisy. |
| `Allow_Ns_User_Export_Net_Policy` | bool | `false` | Lets a namespace-scoped user with runtime-policy read permission export the network policy of their own groups. Turn on for tenant self-service. |

## Policy mode — the core behaviour switch

| field | values | default | meaning |
|---|---|---|---|
| `New_Service_Policy_Mode` | `Discover` \| `Monitor` \| `Protect` | `Discover` | Mode applied to every newly discovered service. `Discover` learns behaviour and blocks nothing. `Monitor` alerts on violations. `Protect` enforces (blocks). Start at `Discover`. |
| `New_Service_Profile_Baseline` | `zero-drift` \| `basic` | `zero-drift` | Process/file baseline. `zero-drift` allows only processes from the original image plus learned ones — stricter and the recommended default. `basic` is the legacy looser model. |

### Mode automation (5.x)

The migration path off `Discover` without touching 800 namespaces by hand. The
controller promotes a service's mode automatically once it has been in the
current mode for the configured duration.

| field | values | default | meaning |
|---|---|---|---|
| `Mode_Auto_D2M` | bool | `false` | Auto-promote Discover → Monitor. |
| `Mode_Auto_D2M_Duration` | seconds, `3600`–`2592000` | `0` | How long a service must sit in Discover first. 1 hour to 30 days. |
| `Mode_Auto_M2P` | bool | `false` | Auto-promote Monitor → Protect. |
| `Mode_Auto_M2P_Duration` | seconds, `3600`–`2592000` | `0` | How long in Monitor first. |

Chart values: `dcs.systemConfig.modeAuto.*`. Wired and off; enabling is a
values-only change, which is exactly the "make it easy in the next release"
requirement.

## Scanning

| field | values | default | meaning |
|---|---|---|---|
| `Scan_Config.Auto_Scan` | bool | `false` | Automatically scan every newly discovered workload image. Convenient, but on a cluster with hundreds of namespaces it produces a large scan backlog on first enable. Turn on deliberately. |
| `Scanner_Autoscale.Strategy` | `""` \| `immediate` \| `delayed` | `""` (off) | Controller-driven scaling of the scanner Deployment. `immediate`: add a pod as soon as the task queue is non-empty. `delayed`: add a pod only after the queue has been non-empty for 90s. Both scale down one pod after the queue has been empty for 180s. |
| `Scanner_Autoscale.Min_Pods` | int | `1` | Floor. |
| `Scanner_Autoscale.Max_Pods` | int | `3` | Ceiling. Bound this against cluster capacity — scanner pods are memory-hungry. |

Note the interaction with our airgap setup: scanner pods use
`imagePullPolicy: Always`, so every scale-up is a registry pull from Harbor.
`delayed` avoids thrashing on short bursts.

## Outbound TLS trust — `Enable_Tls_Verification` / `Cacerts`

These govern the connection NeuVector makes **out** to a registry (Harbor). They
are the fix for `x509: certificate signed by unknown authority` when NeuVector
crawls a registry behind the org PKI.

| field | values | default | meaning |
|---|---|---|---|
| `Enable_Tls_Verification` | bool | `true` | Verify the registry's server certificate. Keep it `true`. Turning it off makes the scan work while silently removing the control. |
| `Cacerts` | list of PEM blocks | empty | Certificates added to NeuVector's trust store for those outbound connections. API field name `cacerts`. |

**You do not need the whole org bundle.** `Cacerts` only has to contain the chain
that signed *Harbor's* certificate — the issuing intermediate and its root. Two
entries, not hundreds. These are public certificates, so they belong in the plain
ConfigMap and are fine in git.

Chart values: `dcs.systemConfig.enableTlsVerification` and
`dcs.systemConfig.caCerts`.

```yaml
dcs:
  systemConfig:
    enableTlsVerification: true
    caCerts:
      - |
        -----BEGIN CERTIFICATE-----
        ... org root ...
        -----END CERTIFICATE-----
      - |
        -----BEGIN CERTIFICATE-----
        ... org issuing intermediate ...
        -----END CERTIFICATE-----
```

This is a different mechanism from the OS trust store. Making the **controller**
trust a private CA for OIDC/LDAP still means getting the bundle to
`/etc/ssl/certs/ca-certificates.crt` (see [oidcinitcfg.md](oidcinitcfg.md)) —
`Cacerts` does not affect that path. The upstream chart exposes
`cve.scanner.volumes` / `cve.scanner.volumeMounts` for mounting extra material
into the scanner, but there is no equivalent for the controller.

## Registry proxy

Only relevant if scanning registries through an HTTP proxy. Irrelevant in the
airgapped environments (Harbor is local); keep disabled.

| field | values | meaning |
|---|---|---|
| `Registry_Http_Proxy_Status` | bool | Enable the HTTP proxy below. |
| `Registry_Https_Proxy_Status` | bool | Enable the HTTPS proxy below. |
| `Registry_Http_Proxy.URL` / `.Username` / `.Password` | string | Proxy endpoint and credentials. **Contains a credential** — if you ever set this, move `sysinitcfg.yaml` out of the ConfigMap and into the SealedSecret (and remove it from the ConfigMap; see Trap 1 in the [README](README.md)). |
| `Registry_Https_Proxy.*` | string | Same for HTTPS. |

## Syslog

Not enabled today (question 21 was "not right now"). Documented for when it is.

| field | values | default | meaning |
|---|---|---|---|
| `Syslog_status` | bool | `false` | Master switch. |
| `Syslog_ip` | IPv4 | — | Destination. IPv4 address, not a hostname. |
| `Syslog_Port` | int | `514` | Destination port. |
| `Syslog_IP_Proto` | `17` \| `6` \| `66` | `17` | UDP / TCP / TCP+TLS. |
| `Syslog_Server_Cert` | PEM | — | Server certificate, **required only when `Syslog_IP_Proto: 66`**. |
| `Syslog_Level` | `Alert`,`Critical`,`Error`,`Warning`,`Notice`,`Info`,`Debug` | `Info` | Minimum severity forwarded. |
| `Syslog_Categories` | list of `event`, `security-event`, `audit` | empty | Which streams to forward. |
| `Syslog_in_json` | bool | `false` | JSON payloads instead of text. Pick this if a SIEM parses it. |
| `single_cve_per_syslog` | bool | `false` | One message per CVE rather than one per scan result. Massively increases volume; only for SIEMs that need per-CVE records. |
| `syslog_cve_in_layers` | bool | `false` | Include per-image-layer CVE detail. |

## Webhooks

| field | meaning |
|---|---|
| `Webhooks[].name` | Display name. |
| `Webhooks[].url` | Target URL. |
| `Webhooks[].type` | `Slack`, `JSON`, or the native format when omitted. |
| `Webhooks[].enable` | bool. |
| `Webhooks[].use_proxy` | Route the call through the configured registry proxy. |

## Network policy

| field | values | default | meaning |
|---|---|---|---|
| `Net_Service_Status` | bool | `false` | Enable policy for unmanaged/network services. |
| `Net_Service_Policy_Mode` | `Discover`\|`Monitor`\|`Protect` | `Discover` | Mode for those services. |
| `Disable_Net_Policy` | bool | `false` | Turn off network policy enforcement entirely. Only for troubleshooting a suspected NeuVector-induced connectivity problem. |

## Platform authentication

| field | values | default | meaning |
|---|---|---|---|
| `Auth_By_Platform` | bool | `false` | Delegate authentication to the underlying platform. **Behaviour on OpenShift at 5.6 is not documented upstream.** This is the one field that might let NeuVector consume OpenShift identity directly instead of going through Keycloak/LDAP — worth an explicit test in dev, but do not design around it until that test passes. |

## Anything else

`dcs.systemConfig.extra` is merged verbatim over the generated file, so a field
that upstream adds tomorrow needs no chart change:

```yaml
dcs:
  systemConfig:
    extra:
      Syslog_status: true
      Syslog_ip: 10.20.30.40
```
