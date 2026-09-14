#!/usr/bin/env python3
"""
Container B (READER) -- covert-channel verification testbed.

Lists blobs in the shared container and prints any token names it finds.
Container B has no network route to Container A; anything it receives arrived
purely through the shared mutable resource.

Polls for a bounded number of attempts so it tolerates arbitrary start order
between the two sandboxes. If nothing is received within the window, it logs
that the channel appears CLOSED -- which is exactly the expected result once
the containment control is applied (per-run containers / scoped SAS).
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
    """Prefer a scoped SAS URL (containment variant b); fall back to the account
    key connection string (the "before" behavior). Backward compatible."""
    sas_url = os.environ.get("BLOB_SAS_URL")
    container = os.environ.get("BLOB_CONTAINER", "covert-channel")
    if sas_url:
        log("Credential: scoped SAS URL (least-privilege, read/list on its OWN container only).")
        return ContainerClient.from_container_url(sas_url)
    conn = os.environ.get("STORAGE_CONNECTION_STRING")
    if not conn:
        raise RuntimeError("neither BLOB_SAS_URL nor STORAGE_CONNECTION_STRING set")
    log("Credential: account key connection string (no containment control).")
    return BlobServiceClient.from_connection_string(conn).get_container_client(container)


def main() -> int:
    container = os.environ.get("BLOB_CONTAINER", "covert-channel")
    poll_seconds = int(os.environ.get("POLL_SECONDS", "10"))
    attempts = int(os.environ.get("ATTEMPTS", "12"))  # ~2 minutes total

    try:
        cc = get_container_client()
    except Exception as e:
        log(f"ERROR: {e}")
        return 1

    log("Container B has NO network route to Container A.")
    log(f"Polling shared resource: container '{container}' "
        f"({attempts} attempts, every {poll_seconds}s)")

    seen = set()
    for i in range(1, attempts + 1):
        new = []
        try:
            for blob in cc.list_blobs():
                if blob.name.startswith("COVERT_CHANNEL_TEST_") and blob.name not in seen:
                    seen.add(blob.name)
                    new.append(blob.name)
        except Exception as e:
            log(f"List failed (attempt {i}/{attempts}): {e}")

        for name in new:
            log(f"RECEIVED token via shared resource: {name}")

        if seen:
            log(f"Channel CONFIRMED OPEN. Tokens received: {len(seen)}")
            return 0

        log(f"Attempt {i}/{attempts}: no tokens yet.")
        time.sleep(poll_seconds)

    log("No tokens received in window. Channel appears CLOSED "
        "(writer not run, or containment control active).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
