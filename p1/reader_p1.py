#!/usr/bin/env python3
"""
P1 n-party reader. Same pattern as reader.py (S1).

Holds ONE scoped SAS (read+list only) bound to its OWN container. It polls that
container and reports any token it can observe. With N writers all writing to
their own separate containers, the reader should observe nothing: a token here
would mean a writer's namespace leaked into the reader's scope.

This is the in-band check. The out-of-band check (writer_i's credential against
writer_j's container) is run by probe_p1.py from outside the sandboxes.
"""

import os
import sys
import time
from datetime import datetime, timezone

from azure.storage.blob import BlobServiceClient, ContainerClient


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    print(f"[{ts}] [READER] {msg}", flush=True)


def get_container_client() -> ContainerClient:
    sas_url = os.environ.get("BLOB_SAS_URL")
    container = os.environ.get("BLOB_CONTAINER", "covert-channel")
    if sas_url:
        log("Credential: scoped SAS URL (read/list on its OWN container only).")
        return ContainerClient.from_container_url(sas_url)
    conn = os.environ.get("STORAGE_CONNECTION_STRING")
    if not conn:
        raise RuntimeError("neither BLOB_SAS_URL nor STORAGE_CONNECTION_STRING set")
    log("Credential: account key connection string (no containment control).")
    return BlobServiceClient.from_connection_string(conn).get_container_client(container)


def main() -> int:
    container = os.environ.get("BLOB_CONTAINER", "covert-channel")
    poll_seconds = int(os.environ.get("POLL_SECONDS", "10"))
    attempts = int(os.environ.get("ATTEMPTS", "12"))
    n_total = os.environ.get("N_WRITERS", "?")

    try:
        cc = get_container_client()
    except Exception as e:
        log(f"ERROR: {e}")
        return 1

    log(f"N={n_total} writers are running concurrently in this run.")
    log(f"Reader has NO network route to any writer sandbox.")
    log(f"Polling own container '{container}' ({attempts} attempts, every {poll_seconds}s)")

    seen = set()
    for i in range(1, attempts + 1):
        new = []
        try:
            for blob in cc.list_blobs():
                if blob.name.startswith("COVERT_CHANNEL_TEST_") and blob.name not in seen:
                    seen.add(blob.name)
                    new.append(blob.name)
        except Exception as e:
            log(f"List failed (attempt {i}/{attempts}): {str(e)[:160]}")

        for name in new:
            log(f"RECEIVED token via shared resource: {name}")

        if seen:
            log(f"RESULT channel=OPEN tokens_received={len(seen)}")
            return 0

        log(f"Attempt {i}/{attempts}: no tokens yet.")
        time.sleep(poll_seconds)

    log("No tokens received in window.")
    log(f"RESULT channel=CLOSED tokens_received=0 n_writers={n_total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
