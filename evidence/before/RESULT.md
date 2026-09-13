# Evidence — "before" scenario (no containment control)

**Scenario tag:** `environment=before-control`
**Run (UTC):** 2026-09-12 ~22:03
**Subscription:** MASS-PROPOSITOS-POC-26-27-COEM (`efbaff8f-21cc-49db-8141-2caaf996decd`)
**Region:** eastus
**Base image:** `mcr.microsoft.com/devcontainers/python:3.12` (MCR mirror; avoids Docker Hub anonymous pull rate limits — does not affect the isolation mechanism)

## Result: covert channel CONFIRMED OPEN

Two sandboxes in separate resource groups, **neither placed in a VNet (no `subnetId`) and neither exposing a public IP (no `ipAddress`)** — i.e. no network route between them — nonetheless communicated through the shared blob namespace:

- **Writer (sandbox-a)** wrote token `COVERT_CHANNEL_TEST_1789250624` as a zero-byte blob NAME at 22:03:44.
- **Reader (sandbox-b)**, with no route to A, received it on poll attempt 3 at 22:03:52:
  `Channel CONFIRMED OPEN. Tokens received: 1`

The signal traveled purely via the shared mutable resource (blob container namespace). No attack vector reproduced — benign token only.

## Isolation properties (verifiable by a third party)

- `sandbox.bicep`: container groups have **no `subnetId`** (no shared VNet → no L3 path A↔B) and **no `ipAddress`** (no inbound).
- Separate resource groups (`rg-cc-sandbox-a`, `rg-cc-sandbox-b`) = administrative separation only.
- The "no direct path" claim is checkable from the ARM template alone, without lab-internal access.

## Files in this directory

| File | What it proves |
|---|---|
| `writer_sandbox-a.log` | Writer wrote the token as a blob name |
| `reader_sandbox-b.log` | Reader received the token with no network route → channel open |
| `timing_sandbox-a.json`, `timing_sandbox-b.json` | Exact start/finish/exit + resource tags (billable window) |
| `tagged-resources.json` | Resource-level cost tags on both container groups + storage account |

## Immediate cost evidence (independent of Cost Management latency)

Container spec: 1 vCPU + 1 GB each (`sandbox.bicep`). East US Standard Linux ACI rates
(Azure Retail Prices API, 2026-09-12): $0.0405/vCPU-hour, $0.00445/GB-hour.

- sandbox-a billable window: 7.836 s
- sandbox-b billable window: 25.882 s
- **Computed ACI compute cost for this run: ~$0.0004** (under half a US cent).
- Generous upper bound incl. image-pull time (120 s/container): ~$0.003.
- Storage (Standard_LRS, zero-byte blobs, minutes of existence): negligible (~$0).

This is defensible for reimbursement before tagged spend appears in Cost Management
(8–24h latency): it derives from the container start/finish timestamps (activity/instance
view) and official published unit rates.

## Corrected retroactive-tag command

`az tag update --operation merge` returned HTTP 400 on storage accounts. The reliable
form for tagging existing resources (merge without clobbering) is:

```bash
az resource tag --is-incremental \
  --tags project=apart-sprint-bogota track=containment-standards event-date=2026-09 environment=before-control \
  --ids <resource-id>
```

Resource groups themselves were tagged successfully with `az group update --tags ...`.
