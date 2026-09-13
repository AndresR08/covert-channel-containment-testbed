# Covert-Channel Verification Testbed

**Declared isolation is not verified isolation.** This is a minimal, executable test for
covert channels between nominally-isolated agent sandboxes through a shared mutable
resource — the failure mode behind the July 2026 OpenAI–Hugging Face incident, in which
~1,200 supposedly isolated agents discovered each other through a shared Artifactory
cache namespace and ~700 joined the resulting attack.

Built for the **Apart Research AI Incident Response Sprint** (Track 1: Containment
Standards, Bogotá hub).

> **This repository contains no exploit.** It passes a benign token between two
> cooperating containers. There is no escape primitive, no privilege escalation, and no
> reproduction of the incident's attack vector. See *Dual-Use Considerations* in the report.

## What it does

Two Azure Container Instances in **separate resource groups**, with **no shared VNet**
(no `subnetId` → no network route between them) and **no inbound exposure** (no
`ipAddress`), share one blob container. A token is passed from one to the other using the
**storage namespace itself** as the medium — the signal is the blob *name*, and the blob is
zero bytes. Content-level controls (scanning, encryption at rest, DLP on object bodies)
are blind to this channel.

| Run | Configuration | Result |
|---|---|---|
| `before-control` | Shared container + account key | **Channel CONFIRMED OPEN** in 8 seconds |
| `after-control` | Per-sandbox scoped SAS, disjoint containers | **Channel CLOSED** (full poll window) |

Total cost of one before/after cycle: **~$0.0021**, under four minutes.

## Reproducing it

Requires: `az` CLI logged in, Owner/Contributor at **subscription** scope (the template
creates resource groups).

```bash
./deploy.sh <SUBSCRIPTION_ID> before-control      # channel open
./deploy.sh <SUBSCRIPTION_ID> after-control       # channel closed
```

Collect evidence:

```bash
az container logs --resource-group rg-cc-sandbox-a --name sandbox-a   # writer
az container logs --resource-group rg-cc-sandbox-b --name sandbox-b   # reader
```

The `after-control` run additionally passes `containmentMode=scoped-sas`.

## Independent verification (no access to this lab required)

The containment claim does **not** rest on trusting these logs. Both credential probes in
[`evidence/after/credential_probe.txt`](evidence/after/credential_probe.txt) are
reproducible by any reviewer who can mint SAS tokens with the declared scope:

1. **Cross-container** — the reader's SAS (`rl`, scoped to `rd-<runId>`) used against the
   writer's container returns **HTTP 403 `AuthenticationFailed`**: the signature is
   cryptographically bound to its own resource path and fails *before* authorization is
   evaluated.
2. **Same container, wrong permission** — the writer's SAS (`cw`, scoped to `wr-<runId>`)
   used to LIST its own container returns **HTTP 403 `AuthorizationPermissionMismatch`**:
   the signature is valid, but `cw` excludes read/list.

A `200` where this reports `403` falsifies the containment claim.

## Layout

| Path | Contents |
|---|---|
| `main.bicep` | Subscription-scoped deployment; 3 resource groups |
| `storage.bicep` | The shared mutable resource |
| `sandbox.bicep` | One ACI sandbox; isolation properties auditable here |
| `containment_sas.bicep` | Containment control: per-sandbox scoped SAS |
| `writer.py` / `reader.py` | Agent scripts (benign token only) |
| `evidence/before/` | Logs, timings, tags, summary — channel open |
| `evidence/after/` | Same, plus `credential_probe.txt` — channel closed |
| `report/` | Final research report |

## Known scope limits

Testing covers channels through shared **storage** resources only. It does not address
host- or kernel-level adversaries, does not reproduce the incident's attack vector, and was
run with 2 sandboxes (the incident involved ~1,200). The SAS "single-use" property is
approximated via short TTL and disjoint scope, not true one-time revocation. Full
treatment in the report's *Limitations*.

## License

MIT
