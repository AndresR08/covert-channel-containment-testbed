#!/usr/bin/env python3
"""
P1 orchestrator: run one N of the n-party sweep end to end.

  deploy N writers + 1 reader  ->  wait for termination  ->  collect logs
  ->  cross-credential probe   ->  write evidence + cost

Usage:
  python run_n.py <SUBSCRIPTION_ID> <N> <RUN_ID> [WRITES] [MAX_PAIRS_PER_WRITER]

Evidence lands in ../evidence/p1/n<N>/. Container groups for the run are deleted
afterwards so quota stays free for the next N; the storage account is kept until
the sweep ends so the probe evidence remains reproducible.
"""

import base64
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime

_AZ = shutil.which("az") or shutil.which("az.cmd") or "az"

VCPU_HR = 0.0405
GB_HR = 0.00445


def az(args, timeout=1800):
    r = subprocess.run([_AZ] + args, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("az failed (%s): %s" % (" ".join(args[:3]), r.stderr.strip()[:400]))
    return r.stdout.strip()


def az_json(args, timeout=1800):
    out = az(args, timeout)
    return json.loads(out) if out else None


def b64_file(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def parse_ts(s):
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    sub, n, run_id = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    writes = sys.argv[4] if len(sys.argv) > 4 else "20"
    max_pairs = sys.argv[5] if len(sys.argv) > 5 else "0"

    outdir = os.path.join("..", "evidence", "p1", "n%d" % n)
    os.makedirs(outdir, exist_ok=True)
    started_wall = time.time()

    print("=== N=%d runId=%s: deploying ===" % (n, run_id), flush=True)
    az(["account", "set", "--subscription", sub])
    dep_name = "p1-nparty-%s-%d" % (run_id, int(time.time()))

    # Parameters go in a file, not on the command line: the base64-injected
    # scripts push the inline form past cmd.exe's 8191-character limit on
    # Windows ("La linea de comandos es demasiado larga").
    params = {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "location": {"value": "eastus"},
            "writerCount": {"value": n},
            "runId": {"value": run_id},
            "writesPerWriter": {"value": int(writes)},
            "containerImage": {"value": "mcr.microsoft.com/devcontainers/python:3.12"},
            "environment": {"value": "p1-nparty-n%d" % n},
            "writerScriptB64": {"value": b64_file("writer_p1.py")},
            "readerScriptB64": {"value": b64_file("reader_p1.py")},
        },
    }
    params_path = os.path.abspath("params_%s.json" % run_id)
    with open(params_path, "w", encoding="utf-8") as f:
        json.dump(params, f)

    res = az_json([
        "deployment", "sub", "create",
        "--name", dep_name,
        "--location", "eastus",
        "--template-file", "main_nparty.bicep",
        "--parameters", "@%s" % params_path,
        "--query", "{state:properties.provisioningState,storage:properties.outputs.storageAccountName.value}",
        "-o", "json",
    ], timeout=3600)
    try:
        os.remove(params_path)
    except OSError:
        pass
    account = res["storage"]
    print("deploy state=%s storage=%s" % (res["state"], account), flush=True)

    names = [("rg-p1-writers", "p1-w%s-%d" % (run_id, i)) for i in range(n)]
    names.append(("rg-p1-reader", "p1-r%s" % run_id))

    print("=== waiting for %d container groups to terminate ===" % len(names), flush=True)
    states = {}
    deadline = time.time() + 3000
    while time.time() < deadline:
        pending = []
        for rg, nm in names:
            if states.get(nm, {}).get("state") == "Terminated":
                continue
            try:
                d = az_json(["container", "show", "-g", rg, "-n", nm, "--query",
                             "{state:containers[0].instanceView.currentState.state,"
                             "exit:containers[0].instanceView.currentState.exitCode,"
                             "start:containers[0].instanceView.currentState.startTime,"
                             "finish:containers[0].instanceView.currentState.finishTime}",
                             "-o", "json"], timeout=180)
            except Exception as e:
                pending.append(nm)
                continue
            if d and d.get("state") == "Terminated":
                states[nm] = d
            else:
                pending.append(nm)
        done = len(states)
        print("  terminated %d/%d" % (done, len(names)), flush=True)
        if done == len(names):
            break
        time.sleep(20)

    print("=== collecting logs ===", flush=True)
    logs = {}
    for rg, nm in names:
        try:
            logs[nm] = az(["container", "logs", "-g", rg, "-n", nm], timeout=300)
        except Exception as e:
            logs[nm] = "LOG FETCH FAILED: %s" % e
    with open(os.path.join(outdir, "containers_n%d.log" % n), "w", encoding="utf-8") as f:
        for rg, nm in names:
            f.write("######## %s (%s) ########\n" % (nm, rg))
            f.write(logs.get(nm, "") + "\n\n")

    # parse writer results
    writers_ok = 0
    writers_failed_containers = []
    total_writes_ok = 0
    total_writes_failed = 0
    err_kinds = {}
    for rg, nm in names:
        if not nm.startswith("p1-w"):
            continue
        txt = logs.get(nm, "")
        if "RESULT writes_ok=" in txt:
            seg = txt.split("RESULT writes_ok=", 1)[1].split()[0]
            fseg = txt.split("writes_failed=", 1)[1].split()[0]
            try:
                total_writes_ok += int(seg)
                wf = int(fseg)
                total_writes_failed += wf
                if wf == 0:
                    writers_ok += 1
                else:
                    writers_failed_containers.append(nm)
            except ValueError:
                writers_failed_containers.append(nm)
        else:
            writers_failed_containers.append(nm)
        if "RESULT error_kinds=" in txt:
            ek = txt.split("RESULT error_kinds=", 1)[1].split("\n")[0].strip()
            if ek and not ek.startswith("{}"):
                err_kinds[nm] = ek

    reader_txt = logs.get("p1-r%s" % run_id, "")
    reader_result = "UNKNOWN"
    if "RESULT channel=" in reader_txt:
        reader_result = reader_txt.split("RESULT channel=", 1)[1].split()[0]

    # cost from billable windows
    resource_seconds = 0.0
    for nm, d in states.items():
        a, b = parse_ts(d.get("start")), parse_ts(d.get("finish"))
        if a and b:
            resource_seconds += (b - a).total_seconds()
    cost = resource_seconds * (VCPU_HR / 3600 + GB_HR / 3600)

    print("=== cross-credential probe ===", flush=True)
    probe_prefix = os.path.join(outdir, "probe_n%d" % n)
    pr = subprocess.run([sys.executable, "probe_p1.py", account, run_id, str(n),
                         probe_prefix, max_pairs], capture_output=True, text=True, timeout=5400)
    print(pr.stdout[-2500:], flush=True)
    if pr.returncode not in (0, 1):
        print("PROBE HARNESS ERROR:", pr.stderr[-1500:], flush=True)
    probe = {}
    try:
        with open(probe_prefix + ".json", encoding="utf-8") as f:
            probe = json.load(f)
    except Exception as e:
        probe = {"error": str(e)}

    summary = {
        "n_writers": n,
        "run_id": run_id,
        "storage_account": account,
        "deployment": dep_name,
        "writes_per_writer": int(writes),
        "containers_terminated": len(states),
        "containers_expected": len(names),
        "writers_all_writes_ok": writers_ok,
        "writers_with_failures": writers_failed_containers,
        "total_writes_ok": total_writes_ok,
        "total_writes_failed": total_writes_failed,
        "writer_error_kinds": err_kinds,
        "reader_result": reader_result,
        "probe_total": probe.get("total_probes"),
        "probe_all_denied": probe.get("all_denied"),
        "probe_violations": probe.get("violations", []),
        "probe_status_counts": probe.get("counts", {}),
        "probe_pair_selection": probe.get("pair_selection"),
        "aci_resource_seconds": round(resource_seconds, 2),
        "aci_cost_usd": round(cost, 6),
        "wall_clock_s": round(time.time() - started_wall, 1),
    }
    with open(os.path.join(outdir, "summary_n%d.json" % n), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print("=== SUMMARY N=%d ===" % n, flush=True)
    print(json.dumps({k: v for k, v in summary.items() if k != "probe_violations"}, indent=2), flush=True)

    print("=== deleting container groups for this N (storage kept) ===", flush=True)
    for rg, nm in names:
        try:
            az(["container", "delete", "-g", rg, "-n", nm, "--yes"], timeout=600)
        except Exception as e:
            print("  delete failed %s: %s" % (nm, e), flush=True)
    print("done N=%d" % n, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
