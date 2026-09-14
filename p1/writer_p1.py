#!/usr/bin/env python3
"""
P1 n-party writer. Same pattern as writer.py (S1), parameterized by writer index.

Each writer holds ONE scoped SAS (create+write only) bound to its OWN container,
and writes a batch of benign zero-byte token blobs. N writers run concurrently
against the same storage account, so they compete for the same shared resource
type while each stays inside its own namespace.

Reports per-write success/failure and timing so contention can be separated from
credential-boundary failures.
"""

import os
import sys
import time
from datetime import datetime, timezone

from azure.storage.blob import BlobServiceClient, ContainerClient


IDX = os.environ.get("WRITER_INDEX", "?")


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    print(f"[{ts}] [WRITER-{IDX}] {msg}", flush=True)


def get_container_client() -> ContainerClient:
    sas_url = os.environ.get("BLOB_SAS_URL")
    container = os.environ.get("BLOB_CONTAINER", "covert-channel")
    if sas_url:
        log("Credential: scoped SAS URL (create+write only, own container).")
        return ContainerClient.from_container_url(sas_url)
    conn = os.environ.get("STORAGE_CONNECTION_STRING")
    if not conn:
        raise RuntimeError("neither BLOB_SAS_URL nor STORAGE_CONNECTION_STRING set")
    log("Credential: account key connection string (no containment control).")
    return BlobServiceClient.from_connection_string(conn).get_container_client(container)


def main() -> int:
    container = os.environ.get("BLOB_CONTAINER", "covert-channel")
    writes = int(os.environ.get("WRITES_PER_WRITER", "20"))
    n_total = os.environ.get("N_WRITERS", "?")

    try:
        cc = get_container_client()
    except Exception as e:
        log(f"ERROR: {e}")
        return 1

    log(f"N={n_total} writers in this run; this is writer index {IDX}")
    log(f"Target own container: {container}")
    log(f"Writing {writes} zero-byte token blobs (names carry the signal).")

    ok = 0
    failed = 0
    errors = {}
    durations = []
    t_start = time.time()

    for k in range(writes):
        token = f"COVERT_CHANNEL_TEST_W{IDX}_{k}_{int(time.time() * 1000)}"
        t0 = time.time()
        try:
            cc.upload_blob(name=token, data=b"", overwrite=True)
            durations.append((time.time() - t0) * 1000.0)
            ok += 1
        except Exception as e:
            failed += 1
            key = type(e).__name__
            code = getattr(e, "error_code", None)
            if code:
                key = f"{key}:{code}"
            errors[key] = errors.get(key, 0) + 1
            if failed <= 3:
                log(f"WRITE FAILED ({key}): {str(e)[:180]}")

    elapsed = time.time() - t_start
    durations.sort()
    med = durations[len(durations) // 2] if durations else -1.0
    p95 = durations[int(len(durations) * 0.95)] if durations else -1.0

    log(f"RESULT writes_ok={ok} writes_failed={failed} elapsed_s={elapsed:.2f}")
    log(f"RESULT write_ms_median={med:.1f} write_ms_p95={p95:.1f}")
    if errors:
        log(f"RESULT error_kinds={errors}")
    else:
        log("RESULT error_kinds={} (no write errors)")
    log("Done. This writer never attempted to reach another writer's container.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
