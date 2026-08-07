# `eulainitcfg.yaml` — licence key

Applies to the **commercial SUSE Security / NeuVector Enterprise** build only.
Contains the licence key → **SealedSecret** if ever used.

**Not used here.** We deploy the open-source images (`neuvector/controller`,
`neuvector/enforcer`, `neuvector/manager`, `neuvector/scanner`), which need no
licence key.

## Fields

| field | required | meaning |
|---|---|---|
| `license_key` | required (when used) | The licence string issued by SUSE. The upstream sample shows it as the single key of the file. |

```yaml
license_key: 0Bca63Iy2FiXGqjk...
```

## What a licence would unlock

If the platform ever moves to the supported build, this file is how the key is
delivered declaratively — and a few chart values become relevant that are
currently inert:

- `core.controller.prime.enabled` and the `neuvector/compliance-config` image —
  extended compliance/benchmark content.
- Vendor support, which for an airgapped regulated environment may matter more
  than any feature difference.

Nothing else in this chart changes: the images swap registry paths, the
configuration surface is identical, and this file is added to the existing
`neuvector-init` SealedSecret as one more key.
