#!/usr/bin/env bash
# P1 n-party sweep: deploy N writer sandboxes + 1 reader against one storage account.
#
# Usage:
#   ./deploy_p1.sh <SUBSCRIPTION_ID> <N> [RUN_ID] [WRITES_PER_WRITER]
#
# Creates only rg-p1-* resource groups. Never touches the S1 groups.

set -euo pipefail

SUBSCRIPTION_ID="${1:-}"
N="${2:-}"
RUN_ID="${3:-n${N}$(date +%s | tail -c 6)}"
WRITES="${4:-20}"
LOCATION="${LOCATION:-eastus}"
IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/python:3.12}"

if [[ -z "$SUBSCRIPTION_ID" || -z "$N" ]]; then
  echo "Usage: ./deploy_p1.sh <SUBSCRIPTION_ID> <N> [RUN_ID] [WRITES_PER_WRITER]" >&2
  exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"

WRITER_B64=$(base64 -w0 writer_p1.py 2>/dev/null || base64 writer_p1.py | tr -d '\n')
READER_B64=$(base64 -w0 reader_p1.py 2>/dev/null || base64 reader_p1.py | tr -d '\n')

DEPLOY_NAME="p1-nparty-${RUN_ID}-$(date +%s)"
echo "deployment : $DEPLOY_NAME"
echo "N writers  : $N"
echo "runId      : $RUN_ID"
echo "writes each: $WRITES"

az deployment sub create \
  --name "$DEPLOY_NAME" \
  --location "$LOCATION" \
  --template-file main_nparty.bicep \
  --parameters \
      location="$LOCATION" \
      writerCount="$N" \
      runId="$RUN_ID" \
      writesPerWriter="$WRITES" \
      containerImage="$IMAGE" \
      environment="p1-nparty-n${N}" \
      writerScriptB64="$WRITER_B64" \
      readerScriptB64="$READER_B64" \
  --query "{state:properties.provisioningState, storage:properties.outputs.storageAccountName.value, runId:properties.outputs.runId.value, n:properties.outputs.writerCount.value}" \
  -o json
