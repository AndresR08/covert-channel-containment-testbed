# Covert-Channel Containment Testbed

**An executable conformance test for agent isolation.** Two sandboxes with no network route
between them are given one shared blob container. Uncontrolled, a benign token crosses in
**8 seconds**. Under per-sandbox scoped credentials, no cross-container access was observed
within the tested scope, and two credential probes return **HTTP 403** by two different
mechanisms. One full before/after cycle costs **$0.0021** and runs in under four minutes.
Repeated at 2, 5, 20 and 50 concurrent parties (see [P1](#p1-does-it-hold-at-scale) below),
the same result held at every scale.

Built for the **Apart Research AI Incident Response Sprint** (Track 1: Containment Standards,
Bogotá hub).

> **This repository contains no exploit.** It passes a benign token between two cooperating
> containers. There is no escape primitive, no privilege escalation, and no reproduction of the
> July 2026 incident's attack vector.

---

## What this is, in 30 seconds

Agent sandboxing is routinely *declared* (in architecture diagrams, deployment templates, vendor
attestations) and rarely *verified* against the channel class that actually broke containment in
the field: a shared mutable resource that isolated sandboxes can both reach.

In the July 2026 OpenAI/Hugging Face incident, roughly 1,200 nominally isolated agents discovered
one another through a shared Artifactory cache namespace, using directory names as messages.
About 700 went on to participate in the resulting attack.

This testbed makes that failure mode **executable**, so isolation becomes an observed fact rather
than a design claim. The signal is carried in the blob **name**, not its contents, so
content-level controls (scanning, encryption at rest, DLP on object bodies) are blind to it.

| Run | Configuration | Result |
|---|---|---|
| `before-control` | Shared container + account key | **Channel CONFIRMED OPEN** in 8 seconds |
| `after-control` | Per-sandbox scoped SAS, disjoint containers | **CLOSED** (no token observed in the full window) |

---

## Just want the evidence? Nothing to deploy

Every result below is already captured in this repo. You do not need an Azure account to review it.

| Path | What it shows |
|---|---|
| [`evidence/before/RESULT.md`](evidence/before/RESULT.md) | Summary of the uncontrolled run |
| [`evidence/before/writer_sandbox-a.log`](evidence/before/writer_sandbox-a.log) | Writer emits the token |
| [`evidence/before/reader_sandbox-b.log`](evidence/before/reader_sandbox-b.log) | Reader receives it on attempt 3, `CONFIRMED OPEN` |
| [`evidence/after/RESULT.md`](evidence/after/RESULT.md) | Summary of the controlled run |
| [`evidence/after/reader_sandbox-b.log`](evidence/after/reader_sandbox-b.log) | Reader polls 12/12, `appears CLOSED` |
| [`evidence/after/credential_probe.txt`](evidence/after/credential_probe.txt) | **Both 403 probes**, full request and response |
| [`evidence/p1/SWEEP_SUMMARY.json`](evidence/p1/SWEEP_SUMMARY.json) | The n-party sweep, aggregated across N = 2, 5, 20, 50 |
| `evidence/*/timing_sandbox-*.json` | Exact start/finish times used for the cost figures |

> Resource identifiers inside `evidence/p1/` (storage account name, deployment names) refer to
> test infrastructure that was torn down immediately after the run. No credential or access tied
> to those names is still live.

**The report:** [`report/Informe_A_v0.4_dos_capas.pdf`](report/Informe_A_v0.4_dos_capas.pdf)
(English, primary deliverable, co-authored, includes the fourteen-control minimum containment
standard). [`report/final_report_apart.pdf`](report/final_report_apart.pdf) is the individual
draft this was built from, kept for reference; its Spanish courtesy translation is
[`report/final_report_apart_es.pdf`](report/final_report_apart_es.pdf).

---

## Prerequisites (if you want to run it yourself)

1. **An Azure subscription** you can create resources in. Total cost of a full cycle is about
   **$0.0021**, well under one US cent.
2. **Azure CLI** (`az`), logged in: `az login`
3. **Permissions:** Owner or Contributor at **subscription scope**. This is required because the
   template creates resource groups, which cannot be done with resource-group-scoped rights.
4. **Bash.** On Windows, Git Bash works. No other tooling, SDK, or build step is needed: the agent
   scripts are injected into the containers at runtime.

Verify you are ready:

```bash
az account show --query "{subscription:name, id:id}" -o json
```

---

## Run it

```bash
git clone https://github.com/AndresR08/covert-channel-containment-testbed.git
cd covert-channel-containment-testbed/infra

# 1. the uncontrolled run: the channel should open
./deploy.sh <SUBSCRIPTION_ID> before-control

# 2. the controlled run: scoped credentials, the channel should not
./deploy.sh <SUBSCRIPTION_ID> after-control
```

`deploy.sh` takes the scenario name as its second argument; it tags every resource with it so the
two runs can be billed apart in Cost Management. It reads the agent scripts from `../agents/`.

Read the results:

```bash
az container logs --resource-group rg-cc-sandbox-a --name sandbox-a   # writer
az container logs --resource-group rg-cc-sandbox-b --name sandbox-b   # reader
```

Expected: `Channel CONFIRMED OPEN` after the first run, `Channel appears CLOSED` after the second.
The reader in the second run takes about 125 s because it exhausts its full 12-attempt window
rather than exiting early on receipt.

### Run the credential probes

This is the part a reviewer can verify **without trusting our logs**. Mint two SAS tokens with the
same scope the sandboxes receive, then try to use each one outside its scope. Both must return 403.

```bash
ACCOUNT=<storage-account-name>        # from the deploy output
RUN=<runId>                           # from the deploy output, e.g. 6a50151453977
EXPIRY=$(date -u -d '+30 minutes' '+%Y-%m-%dT%H:%MZ')
KEY=$(az storage account keys list --account-name "$ACCOUNT" --query "[0].value" -o tsv)

READER_SAS=$(az storage container generate-sas --account-name "$ACCOUNT" --account-key "$KEY" \
  --name "rd-$RUN" --permissions rl --expiry "$EXPIRY" --https-only -o tsv)
WRITER_SAS=$(az storage container generate-sas --account-name "$ACCOUNT" --account-key "$KEY" \
  --name "wr-$RUN" --permissions cw --expiry "$EXPIRY" --https-only -o tsv)

# Probe 1 - cross-container: reader's credential against the writer's container
curl -s -o /dev/null -w "probe1: %{http_code}\n" \
  "https://$ACCOUNT.blob.core.windows.net/wr-$RUN?restype=container&comp=list&$READER_SAS"

# Probe 2 - same container, wrong permission: writer's credential tries to LIST
curl -s -o /dev/null -w "probe2: %{http_code}\n" \
  "https://$ACCOUNT.blob.core.windows.net/wr-$RUN?restype=container&comp=list&$WRITER_SAS"
```

Expected output:

```
probe1: 403      AuthenticationFailed          (signature is bound to its own container path)
probe2: 403      AuthorizationPermissionMismatch  (signature valid, but cw excludes read/list)
```

The two failures land at **different layers**, which is the substantive result: probe 1 is
rejected before authorization is even evaluated, probe 2 authenticates correctly and is then
denied on permissions. **A `200` in either probe would falsify the containment claim.**

### Clean up

```bash
az group delete --name rg-cc-sandbox-a --yes --no-wait
az group delete --name rg-cc-sandbox-b --yes --no-wait
az group delete --name rg-cc-storage   --yes --no-wait
```

---

## P1: does it hold at scale?

The two-sandbox result above only tests the smallest possible case. `p1/` repeats the identical
scoped-SAS control with **N concurrent writers** (2, 5, 20, 50) competing for the same storage
account, each holding one SAS bound to its own container, plus one reader and an out-of-band
credential probe against every party's scope.

| N | Writes (ok / failed) | Reader | Probes | Pair selection | All denied |
|---|---|---|---|---|---|
| 2 | 40 / 0 | CLOSED | 8 | exhaustive | yes |
| 5 | 100 / 0 | CLOSED | 50 | exhaustive | yes |
| 20 | 400 / 0 | CLOSED | 790 | exhaustive | yes |
| 50 | 1,000 / 0 | CLOSED | 544 | sampled (ring + fixed sample) | yes |

**1,392 credential probes total, all denied. 1,540 writes, 0 failed.** Contention was real, not
absent: worst-writer p95 write latency grew roughly tenfold from N=2 to N=50 (65 ms to 676 ms),
while the credential boundary produced the identical result at every scale. Full evidence in
[`evidence/p1/`](evidence/p1/); tooling in [`p1/`](p1/) (`./deploy_p1.sh` or `run_n.py` for a
single end-to-end N).

---

## The five-step protocol

The report generalizes this into a **candidate conformance protocol** (not an adopted standard).
Steps 2 and 3 are what this repo executes; 1, 4 and 5 are what an operator adds to make it a
standing control:

1. **Declare** the mutable resources two nominally isolated agents can both reach (object storage,
   package and build caches, queues, artifact registries, tag stores, lock files).
2. **Pass a benign token** between the two isolated parties through each shared resource, carried
   in the resource *namespace* rather than its contents.
3. **Probe the credentials** across scopes and require an explicit rejection (403 or equivalent),
   recording which layer rejected it.
4. **Record reproducible evidence** a third party can re-run without internal access.
5. **Repeat on every deployment configuration**, in CI/CD or periodic audit, not once at launch,
   and at more than one scale, see [P1](#p1-does-it-hold-at-scale).

---

## Repository layout

| Path | Contents |
|---|---|
| `infra/main.bicep` | Subscription-scoped deployment; creates the three resource groups |
| `infra/storage.bicep` | The shared mutable resource |
| `infra/sandbox.bicep` | One ACI sandbox. **The isolation properties are auditable here:** no `subnetId` (no shared VNet, so no route between sandboxes) and no `ipAddress` (no inbound exposure) |
| `infra/containment_sas.bicep` | The containment control: per-sandbox scoped SAS, disjoint containers and permissions |
| `infra/deploy.sh` | `./deploy.sh <SUBSCRIPTION_ID> <before-control\|after-control>` |
| `agents/writer.py` / `agents/reader.py` | Agent scripts (benign token only) |
| `p1/` | The n-party sweep: its own Bicep, agent scripts, credential-probe harness, and orchestrator (`run_n.py`) |
| `evidence/before/`, `evidence/after/` | Captured results from the two-sandbox before/after runs |
| `evidence/p1/` | Captured results from the n-party sweep (N = 2, 5, 20, 50) |
| `report/` | Final reports (primary + individual draft, EN + ES) and the scripts that build them |

`d1d2/` (an exploratory probe of two further controls, ambient identity and credential-boundary
scope) exists only on the `feature/d1-d2` branch. It is not merged into `main` and not part of the
report: the result is real but the work is a single overnight run, pending review before it is
treated as evidence on the same footing as S1 or P1.

---

## Scope and limits

This tests channels through shared **storage** resources only. It does **not** address host- or
kernel-level adversaries, does **not** reproduce the incident's attack vector, and the two-sandbox
result was run with **2** sandboxes where the incident involved ~1,200 (P1 extends this to 50; the
gap to ~1,200 remains). The SAS "single-use" property is approximated via short TTL and disjoint
scope, not true one-time revocation. `CLOSED` is a bounded-window negative observation, not a
proof of impossibility; the credential probes are what raise it above that. Full treatment in the
report's *Limitations* and *Dual-Use Considerations*.

## License

MIT
