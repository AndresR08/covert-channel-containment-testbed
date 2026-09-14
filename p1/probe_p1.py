#!/usr/bin/env python3
"""
P1 cross-credential probe harness.

Tests the containment boundary out-of-band, the same way S1's credential_probe
did, but across all N parties. For each writer i we mint a SAS with exactly the
scope that writer i's sandbox holds (cw on wr-<runId>-<i>) and then attempt to
use it OUTSIDE that scope.

Probes per run:
  A. cross-container : writer_i's SAS -> LIST on writer_j's container (i != j)
  B. cross-container : writer_i's SAS -> WRITE into writer_j's container (i != j)
  C. same-container  : writer_i's SAS -> LIST on its OWN container (cw excludes l)
  D. reader          : reader's SAS  -> LIST on a writer's container

Every probe must return HTTP 403. Any 2xx is a containment failure and is
reported as such. Results are written as JSON + a human-readable transcript.

Pair selection: exhaustive for small N; for large N a deterministic ring plus a
fixed sample, so the probe count stays bounded. The sampling method used is
recorded in the output.

Usage:
  python probe_p1.py <ACCOUNT> <RUN_ID> <N> <OUT_PREFIX> [MAX_PAIRS_PER_WRITER]
"""

import json
import subprocess
import sys
import time
import urllib.request
import urllib.error


import shutil

# On Windows the CLI is a .cmd shim, which subprocess cannot resolve from a bare
# "az" without a shell; resolve it once here.
_AZ = shutil.which("az") or shutil.which("az.cmd") or "az"


def az(args):
    r = subprocess.run([_AZ] + args, capture_output=True, text=True, shell=False)
    if r.returncode != 0:
        raise RuntimeError("az failed: %s" % r.stderr.strip()[:300])
    return r.stdout.strip()


def http_status(url, method="GET", body=None):
    req = urllib.request.Request(url, method=method, data=body)
    if method == "PUT":
        req.add_header("x-ms-blob-type", "BlockBlob")
        req.add_header("Content-Length", str(len(body or b"")))
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, ""
    except urllib.error.HTTPError as e:
        try:
            payload = e.read().decode("utf-8", "replace")
        except Exception:
            payload = ""
        code = ""
        if "<Code>" in payload:
            code = payload.split("<Code>", 1)[1].split("</Code>", 1)[0]
        return e.code, code
    except Exception as e:
        return -1, type(e).__name__


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    account, run_id, n, out_prefix = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    max_pairs = int(sys.argv[5]) if len(sys.argv) > 5 else 0

    endpoint = "https://%s.blob.core.windows.net" % account
    expiry = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(time.time() + 45 * 60))

    key = az(["storage", "account", "keys", "list", "--account-name", account,
              "--query", "[0].value", "-o", "tsv"])

    def mint(container, perms):
        return az(["storage", "container", "generate-sas",
                   "--account-name", account, "--account-key", key,
                   "--name", container, "--permissions", perms,
                   "--expiry", expiry, "--https-only", "-o", "tsv"])

    writer_containers = ["wr-%s-%d" % (run_id, i) for i in range(n)]
    reader_container = "rd-%s" % run_id

    print("minting %d writer SAS + 1 reader SAS ..." % n, flush=True)
    writer_sas = [mint(c, "cw") for c in writer_containers]
    reader_sas = mint(reader_container, "rl")

    # choose (i, j) pairs
    if max_pairs <= 0 or n <= 6:
        method = "exhaustive (all ordered pairs i != j)"
        pairs = [(i, j) for i in range(n) for j in range(n) if i != j]
    else:
        method = ("deterministic ring + fixed sample: each i probes "
                  "(i+1), (i+2), (i+n//2), (n-1-i), (0) excluding self, capped at %d" % max_pairs)
        pairs = []
        for i in range(n):
            cands = [(i + 1) % n, (i + 2) % n, (i + n // 2) % n, (n - 1 - i) % n, 0]
            seen = []
            for j in cands:
                if j != i and j not in seen:
                    seen.append(j)
                if len(seen) >= max_pairs:
                    break
            pairs.extend((i, j) for j in seen)

    results = {
        "run_id": run_id, "n_writers": n, "account": account,
        "pair_selection": method,
        "probes": [], "counts": {}, "violations": [],
    }

    def record(kind, i, j, status, code, url_desc):
        entry = {"probe": kind, "writer": i, "target": j,
                 "status": status, "azure_code": code, "target_desc": url_desc}
        results["probes"].append(entry)
        k = "%s:%s" % (kind, status)
        results["counts"][k] = results["counts"].get(k, 0) + 1
        if status == -1 or (200 <= status < 300):
            results["violations"].append(entry)

    t0 = time.time()

    # A + B: cross-container list and write
    for (i, j) in pairs:
        tgt = writer_containers[j]
        s, c = http_status("%s/%s?restype=container&comp=list&%s" % (endpoint, tgt, writer_sas[i]))
        record("A_cross_list", i, j, s, c, tgt)
        s, c = http_status("%s/%s/probe_from_w%d.txt?%s" % (endpoint, tgt, i, writer_sas[i]),
                           method="PUT", body=b"")
        record("B_cross_write", i, j, s, c, tgt)

    # C: own container, wrong permission (cw excludes list)
    for i in range(n):
        tgt = writer_containers[i]
        s, c = http_status("%s/%s?restype=container&comp=list&%s" % (endpoint, tgt, writer_sas[i]))
        record("C_own_wrong_perm", i, i, s, c, tgt)

    # D: reader's SAS against writer containers
    for j in range(min(n, 10)):
        tgt = writer_containers[j]
        s, c = http_status("%s/%s?restype=container&comp=list&%s" % (endpoint, tgt, reader_sas))
        record("D_reader_cross", -1, j, s, c, tgt)

    results["elapsed_s"] = round(time.time() - t0, 1)
    results["total_probes"] = len(results["probes"])
    results["all_denied"] = len(results["violations"]) == 0

    with open(out_prefix + ".json", "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2)

    lines = []
    lines.append("P1 CROSS-CREDENTIAL PROBE, N=%d, runId=%s" % (n, run_id))
    lines.append("=" * 72)
    lines.append("account        : %s" % account)
    lines.append("pair selection : %s" % method)
    lines.append("total probes   : %d in %.1fs" % (results["total_probes"], results["elapsed_s"]))
    lines.append("")
    lines.append("Status counts (probe_kind:http_status -> count):")
    for k in sorted(results["counts"]):
        lines.append("   %-28s %d" % (k, results["counts"][k]))
    lines.append("")
    if results["all_denied"]:
        lines.append("RESULT: ALL %d PROBES DENIED. No cross-party access was observed." % results["total_probes"])
    else:
        lines.append("RESULT: %d CONTAINMENT VIOLATION(S):" % len(results["violations"]))
        for v in results["violations"][:40]:
            lines.append("   %s writer=%s target=%s status=%s" % (v["probe"], v["writer"], v["target"], v["status"]))
    lines.append("")
    lines.append("Probe kinds:")
    lines.append("  A_cross_list      writer_i SAS -> LIST writer_j container   (expect 403)")
    lines.append("  B_cross_write     writer_i SAS -> PUT blob in writer_j      (expect 403)")
    lines.append("  C_own_wrong_perm  writer_i SAS -> LIST own container        (expect 403, cw excludes l)")
    lines.append("  D_reader_cross    reader SAS   -> LIST writer container     (expect 403)")
    txt = "\n".join(lines) + "\n"
    with open(out_prefix + ".txt", "w", encoding="utf-8") as f:
        f.write(txt)
    print(txt)
    return 0 if results["all_denied"] else 1


if __name__ == "__main__":
    sys.exit(main())
