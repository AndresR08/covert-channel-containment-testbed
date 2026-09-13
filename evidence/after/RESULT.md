# Evidence — "after" scenario (containment control: variant (b), scoped SAS)

**Scenario tag:** `environment=after-control`
**Run (UTC):** 2026-09-12 ~22:26–22:28
**Subscription:** MASS-PROPOSITOS-POC-26-27-COEM (`efbaff8f-21cc-49db-8141-2caaf996decd`)
**Region:** eastus
**Base image:** `mcr.microsoft.com/devcontainers/python:3.12` (same as "before" run — controlled comparison)
**Containment mode:** `scoped-sas` — per-sandbox short-lived, least-privilege SAS; no account key handed to either sandbox
**Run ID:** `6a50151453977` → containers `wr-6a50151453977` (writer), `rd-6a50151453977` (reader)

## Result: covert channel appears CLOSED

```
[WRITER] Credential: scoped SAS URL (least-privilege, write-only container).
[WRITER] Target shared resource: container 'wr-6a50151453977'
[WRITER] Token written. blob_name = COVERT_CHANNEL_TEST_1789252005

[READER] Credential: scoped SAS URL (least-privilege, read/list on its OWN container only).
[READER] Polling shared resource: container 'rd-6a50151453977' (12 attempts, every 10s)
[READER] Attempt 1/12 ... Attempt 12/12: no tokens yet.
[READER] No tokens received in window. Channel appears CLOSED (writer not run, or containment control active).
```

The writer succeeded (proving the mechanism still works end-to-end) but wrote into
`wr-<runId>`, a namespace the reader never touches. The reader ran its **full**
12-attempt / ~124s poll window (vs. ~26s in "before", where it found the token on
attempt 3) — the longer run itself is corroborating evidence: absence, not a shortened
test.

## Why this closes the specific channel "before" demonstrated open

"Before" relied on two enabling properties, both removed here:
1. **Shared namespace** — both sandboxes pointed at the same container. Now they
   write/read disjoint per-run containers (`wr-<runId>` / `rd-<runId>`).
2. **Broad credential** — both held the full account key. Now each holds only a
   SAS scoped to its own container with a minimal permission set (writer: `cw`
   create+write only; reader: `rl` read+list only). Neither sandbox has the
   account key.

## Third-party verification (no lab-internal access required)

Two independent lines of evidence, at increasing strength:

1. **Template inspection** — `containment_sas.bicep` shows the writer/reader SAS
   are minted with disjoint `canonicalizedResource` (different containers) and
   disjoint `signedPermission` (cw vs rl). This alone establishes the design intent.
2. **Runnable credential probe** (`credential_probe.txt`) — the strongest proof,
   independently reproducible by anyone who can mint SAS tokens against test
   containers with the same declared scope, no lab access needed:
   - **Cross-container:** reader's SAS (rl, scoped to `rd-<runId>`) used against
     the writer's container → **HTTP 403 AuthenticationFailed** (signature is
     cryptographically bound to its own resource path; fails before
     authorization is even evaluated).
   - **Same-container, wrong permission:** writer's SAS (cw, scoped to
     `wr-<runId>`) used to attempt LIST on its own container → **HTTP 403
     AuthorizationPermissionMismatch** (signature valid, but `cw` excludes
     read/list — least-privilege enforced even within its own scope).

## Files in this directory

| File | What it proves |
|---|---|
| `writer_sandbox-a.log` | Writer succeeded using only a scoped SAS (no account key) |
| `reader_sandbox-b.log` | Reader polled its full window and found nothing → CLOSED |
| `credential_probe.txt` | Independently runnable proof: both probes return 403, for different reasons (auth-layer vs. authz-layer denial) |
| `timing_sandbox-a.json`, `timing_sandbox-b.json` | Exact start/finish/exit + resource tags (billable window) |
| `tagged-resources.json` | Resource-level cost tags on both container groups + storage account |

## Immediate cost evidence

Container spec: 1 vCPU + 1 GB each. East US Standard Linux ACI rates:
$0.0405/vCPU-hour, $0.00445/GB-hour.

- sandbox-a (writer) billable window: 7.904 s
- sandbox-b (reader) billable window: 125.445 s (full poll window — expected,
  since no early exit on token receipt)
- **Computed ACI compute cost for this run: ~$0.00167** (about 4x "before"'s
  cost, entirely explained by the reader running its full window instead of
  exiting early on receipt — not by any infrastructure difference).
- Storage: negligible (2 new empty containers, zero-byte blob).

## Comparison with "before" (side by side)

| | before | after (scoped-sas) |
|---|---|---|
| Credential | account key (full account) | per-sandbox SAS (own container only) |
| Namespace | shared `covert-channel` | disjoint `wr-<runId>` / `rd-<runId>` |
| Reader result | `CONFIRMED OPEN`, token received on attempt 3 (~26s) | `CLOSED`, full 12/12 attempts (~124s) |
| Compute cost | ~$0.00042 | ~$0.00167 |
| 3rd-party proof | template inspection (no VNet/subnetId) | template inspection **+ runnable 403 credential probe** |

## Known caveat, stated honestly for the report

Azure SAS is a bearer token valid until expiry — **not natively single-use**.
This build approximates "single-use" via: short TTL (30 min), disjoint
per-sandbox container scope, and minimal (non-overlapping) permission sets.
No stored access policy / hard revocation is implemented in this build (kept
out of scope for the sprint deadline, per explicit decision). Should not be
described as true single-use in the final report — the accurate phrase is:
**"short-lived, least-privilege, per-sandbox scoped SAS."**

## Note on the shared storage account's tag

`ccstor3xnygvmi7f3z` (the one canonical storage account, reused across both
runs) now shows `environment=after-control` — this deploy's tag value
overwrote the account-level tag previously set to `before-control`. This is
expected behavior of tag application (not a data-loss issue): the
`before-control` run's evidence files (`evidence/before/tagged-resources.json`)
still accurately document the tag *as observed at that time*. The two
container groups (`sandbox-a`, `sandbox-b`) are reused across runs the same
way, so this pattern is consistent for all three resources, not just storage.
Cost Management's per-resource tag is a point-in-time label, not a
historical ledger — for exact per-run cost attribution, this report relies
on the timing-based computed cost (above), not on the live tag value.
