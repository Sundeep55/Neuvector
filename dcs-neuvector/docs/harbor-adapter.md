# Registering the NeuVector adapter in Harbor

Everything below is verified against `neuvector/registry-adapter@v0.2.9`
(`server/server.go`), not inferred from documentation.

## The three facts that decide everything

**1. The URL path is `/endpoint`, and it is not optional.**

The adapter registers exactly three routes:

```go
scanReportURL    = "/endpoint/api/v1/scan/"
scanEndpoint     = "/endpoint/api/v1/scan"
metadataEndpoint = "/endpoint/api/v1/metadata"
http.HandleFunc("/", unhandled)          // -> 404 "404 page not found"
```

Harbor appends `/api/v1/metadata` to whatever you type in the Endpoint field.
So the Endpoint **must end in `/endpoint`**:

| Endpoint you type | adapter receives | result |
|---|---|---|
| `https://host:9443/endpoint` | `/endpoint/api/v1/metadata` | correct |
| `https://host:9443` | `/api/v1/metadata` | `Unhandled HTTP Endpoint` → 404 |
| `https://host:9443/endpoint/api/v1/metadata` | `/endpoint/api/v1/metadata/api/v1/metadata` | 404 |

**2. The port is 9443, and it must be explicit.**

```go
adapterHttpsPort = "9443"   // when cve.adapter.harbor.protocol = https
adapterHttpPort  = "8090"   // when it is http
```

The Service publishes 9443. A URL with no port goes to 443, where nothing
listens — that is what produces `context deadline exceeded`, not a network
policy.

**3. The adapter reads its certificate once, at process start.**

```go
certFile = "/etc/neuvector/certs/ssl-cert.pem"
keyFile  = "/etc/neuvector/certs/ssl-cert.key"
```

If either file is missing at startup it **generates a self-signed certificate**
and serves that. Consequences:

- Mounting a cert secret after the pod started changes nothing until the pod is
  restarted. (This is why an endpoint can look "insecure" one day and "secure"
  the next — a restart happened in between.)
- cert-manager renewal is likewise not picked up until restart. Add a reloader
  annotation via `core.cve.adapter.podAnnotations`, or restart deliberately.

## In-cluster Harbor (hub) — recommended

Values: leave `core.cve.adapter.certificate.secret` at the chart default
`dcs-neuvector-adapter-certs`, which `templates/certificate-adapter.yaml` issues
for the Service DNS names. No Route needed.

Harbor → Administration → Interrogation Services → **+ NEW SCANNER**:

| field | value |
|---|---|
| Endpoint | `https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/endpoint` |
| Authorization | **Basic** |
| Username / Password | the pair sealed as `dcs-neuvector-adapter-auth` |
| Skip certificate verification | tick it, **unless** you add the internal CA to Harbor's trust store |

Use the **fully qualified** name. The short name `neuvector-service-registry-adapter`
does not resolve from another namespace, and if harbor-core has a proxy
configured it will be sent to the proxy (see "Forbidden" below).

To verify without skipping TLS, give Harbor the CA:

```bash
oc -n dcs-neuvector get secret dcs-neuvector-internal-certs \
  -o jsonpath='{.data.ca\.crt}' | base64 -d
```

## External Harbor (dev) — via Route

Values:

```yaml
core:
  cve:
    adapter:
      enabled: true
      # Route is passthrough, so the pod serves this cert directly and its SAN
      # must equal the Route host exactly.
      certificate:
        secret: dcs-neuvector-external-certs
        keyFile: tls.key
        pemFile: tls.crt
      harbor:
        protocol: https
        secretName: dcs-neuvector-adapter-auth
      route:
        enabled: true
        termination: passthrough
        host: nv-adapter.<baseDomain>     # lowercase, and a SAN of the cert
```

Harbor scanner registration:

| field | value |
|---|---|
| Endpoint | `https://nv-adapter.<baseDomain>/endpoint` |
| Authorization | **Basic** |
| Skip certificate verification | not needed if the org CA is trusted and the SAN matches |

**No port.** A passthrough Route terminates on the OpenShift router at **443**;
9443 is the in-cluster Service port and is not reachable from outside.

**Lowercase only.** Route and DNS hostnames are RFC-1123: `NV-adapter...` is
invalid. Whatever the final host is, it must appear verbatim as a SAN in
`dcs-neuvector-external-certs`.

## Reading the failure modes

| symptom | cause |
|---|---|
| adapter log `Unhandled HTTP Endpoint - endpoint=/api/v1/metadata` | Endpoint missing the `/endpoint` suffix |
| Harbor `context deadline exceeded` | no `:9443` in the URL (went to 443) |
| Harbor `x509: certificate signed by unknown authority` | Harbor does not trust the adapter's CA — tick skip-verify or add the CA. Connectivity is fine at this point |
| Harbor `does not support scanning artifact with mime type ...` | almost always a failed metadata ping, not a mime problem — see "The mime-type error is a lie" |
| Harbor `Forbidden` | an HTTP proxy refused `CONNECT`. Go surfaces a failed proxy CONNECT as an error whose text is the proxy's status line. Check `oc -n <harbor-ns> set env deploy/harbor-core --list \| grep -i -e proxy`, and make sure `NO_PROXY` covers the name you are dialling |
| Harbor `invalid character ... looking for beginning of value` | the adapter requires basic auth but Harbor was registered with Authorization = None. With no `Authorization` header the middleware neither serves the request nor writes an error, so Go emits an empty `200` and Harbor fails to parse it |
| browser shows an untrusted cert | the pod started before the cert secret existed and generated a self-signed one — restart the deployment |

## The mime-type error is a lie

```
the configured scanner <name> does not support scanning artifact
with mime type application/vnd.oci.image.manifest.v1+json
```

This almost never means what it says. The adapter *does* advertise that mime
type — `server/server.go` returns
`consumes_mime_types: [application/vnd.oci.image.manifest.v1+json,
application/vnd.docker.distribution.manifest.v2+json]` — and Harbor's struct
tags match it exactly, so the JSON parses correctly.

Harbor reaches that message through:

```go
// src/controller/scan/checker.go
func hasCapability(r *models.Registration, a *artifact.Artifact) bool {
    allowlist := []string{image.ArtifactTypeImage}
    if slices.Contains(allowlist, a.Type) {
        return r.HasCapability(a.ManifestMediaType)
    }
    return false
}

// src/pkg/scan/dao/scanner/model.go
func (r *Registration) HasCapability(mt string) bool {
    if r.Metadata == nil { return false }     // <-- the usual culprit
    ...
}
```

So there are only two ways to see it:

1. **`a.Type != image`** — the artifact is a Helm OCI chart, cosign signature or
   SBOM attachment rather than an image. Ruled out if another scanner (Trivy)
   scans the same artifact successfully.
2. **`r.Metadata == nil`** — Harbor pings the adapter for metadata on *every*
   scan (`Ping: true` is the default in `newOptions`) and, on failure, logs the
   error, sets health to unhealthy and leaves `Metadata` nil. The scan then
   reports a mime-type problem instead of the connection problem that actually
   happened.

### Finding the real error

Harbor logs the true cause one line earlier, with a different prefix:

```bash
oc -n <harbor-ns> logs deploy/harbor-core | grep "api controller: get project scanner"
```

Or ask Harbor to fetch the metadata directly — this is the same `Ping` call the
scan path makes:

```bash
curl -su <admin> https://registry.x.com/api/v2.0/scanners/<registration_id>/metadata
```

Healthy output contains `consumes_mime_types`. An error there is the real fault.

### Why registration can succeed while scanning fails

Registration runs the same ping, so a scanner that registered cleanly proves the
ping worked *from whichever core pod handled that request, at that moment*. Two
things break the symmetry:

- **Multiple `harbor-core` replicas.** If the trusted-CA bundle was added and
  only some pods restarted, registration may land on a good replica and scans on
  a stale one. Restart every core replica, not just one.
- **Adapter startup ordering.** The adapter blocks in
  `for nvScanner.Version == "" { pollMaxConcurrent() }` *before* it registers any
  handler or listens, so while the NeuVector controller is unreachable nothing is
  listening on 9443 at all — connections are refused and the ping fails. The
  adapter log shows `START - version=...` and then nothing.

Note also that `getScannerAdapterMetadataWithCache` caches the **error**, not
just the success, in a 30-second in-memory cache. Wait out the 30s before
concluding a fix did not work.

## Prove the adapter before touching Harbor

```bash
U=$(oc -n dcs-neuvector get secret dcs-neuvector-adapter-auth -o jsonpath='{.data.username}' | base64 -d)
P=$(oc -n dcs-neuvector get secret dcs-neuvector-adapter-auth -o jsonpath='{.data.password}' | base64 -d)

oc -n dcs-neuvector run adapter-check --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sk -u "$U:$P" \
  https://neuvector-service-registry-adapter.dcs-neuvector.svc.cluster.local:9443/endpoint/api/v1/metadata
```

A healthy adapter returns JSON naming the NeuVector scanner and its capabilities.
Anything else, match it against the table above. Only once this returns JSON is
it worth debugging Harbor.

Note that the adapter blocks at startup until it can reach the controller and
learn the scanner version (`for nvScanner.Version == "" { ... }`), so on a fresh
install the metadata endpoint stays unavailable until the controller and at
least one scanner pod are up.
