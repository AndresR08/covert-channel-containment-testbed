#!/usr/bin/env python3
"""
Container A (WRITER) -- covert-channel verification testbed.

Writes a benign token as a BLOB NAME into the shared storage container.
The signal is carried in the namespace itself (the blob name), not in any
content -- this mirrors the incident pattern where a shared cache namespace
was used as a message board. The blob is zero bytes.

Container A has no network route to Container B. If B can later read this
name, the channel through the shared mutable resource is open.
"""

import os
import sys
import time
from datetime import datetime, timezone

from azure.storage.blob import BlobServiceClient, ContainerClient


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    print(f"[{ts}] [WRITER] {msg}", flush=True)


def get_container_client() -> ContainerClient:
    """Prefer a scoped SAS URL (containment variant b); fall back to the account
    key connection string (the "before" behavior). Backward compatible."""
    sas_url = os.environ.get("BLOB_SAS_URL")
    container = os.environ.get("BLOB_CONTAINER", "covert-channel")
    if sas_url:
        log("Credential: scoped SAS URL (least-privilege, write-only container).")
        return ContainerClient.from_container_url(sas_url)
    conn = os.environ.get("STORAGE_CONNECTION_STRING")
    if not conn:
        raise RuntimeError("neither BLOB_SAS_URL nor STORAGE_CONNECTION_STRING set")
    log("Credential: account key connection string (no containment control).")
    return BlobServiceClient.from_connection_string(conn).get_container_client(container)


def main() -> int:
    container = os.environ.get("BLOB_CONTAINER", "covert-channel")

    try:
        cc = get_container_client()
    except Exception as e:
        log(f"ERROR: {e}")
        return 1

    token = f"COVERT_CHANNEL_TEST_{int(time.time())}"

    log("Container A has NO network route to Container B.")
    log(f"Target shared resource: container '{container}'")
    log(f"Writing token as a zero-byte blob NAME: {token}")

    # The token is the name. Content is empty on purpose -- the namespace is the channel.
    cc.upload_blob(name=token, data=b"", overwrite=True)

    log(f"Token written. blob_name = {token}")
    log("Done. If Container B reads this name, the covert channel is CONFIRMED open.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
