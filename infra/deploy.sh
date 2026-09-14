#!/usr/bin/env bash
# Deploy the covert-channel testbed.
#
# Usage:
#   ./deploy.sh <SUBSCRIPTION_ID> <ENVIRONMENT> [LOCATION] [CONTAINER_IMAGE]
#
# ENVIRONMENT is the cost-traceability scenario tag. Use it to bill each run
# separately in Cost Management, e.g.:
#   ./deploy.sh <SUB_ID> before-control      # the "before" run (no containment)
#   ./deploy.sh <SUB_ID> after-control       # the "after" run (containment active)
#
# CONTAINER_IMAGE defaults to an MCR-hosted image to avoid Docker Hub anonymous
# pull rate limits from ACI shared egress IPs. Override if you need a specific one.
#
# Requires: az CLI logged in, and Owner/Contributor at SUBSCRIPTION scope
# (the template creates resource groups). Default region: eastus.
#
# Run from inside infra/ (this directory) -- it reads the agent scripts from
# ../agents/writer.py and ../agents/reader.py.

set -euo pipefail

SUBSCRIPTION_ID="${1:-TU_SUBSCRIPTION_ID}"
ENVIRONMENT="${2:-}"
LOCATION="${3:-eastus}"
CONTAINER_IMAGE="${4:-mcr.microsoft.com/devcontainers/python:3.12}"

if [[ "$SUBSCRIPTION_ID" == "TU_SUBSCRIPTION_ID" || -z "$ENVIRONMENT" ]]; then
  echo "Usage: ./deploy.sh <SUBSCRIPTION_ID> <ENVIRONMENT> [LOCATION] [CONTAINER_IMAGE]" >&2
  echo "  ENVIRONMENT distinguishes the run, e.g. before-control or after-control" >&2
  exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"

# Inject the Python scripts as base64 (GNU base64 uses -w0; macOS has no -w0).
WRITER_B64=$(base64 -w0 ../agents/writer.py 2>/dev/null || base64 ../agents/writer.py | tr -d '\n')
READER_B64=$(base64 -w0 ../agents/reader.py 2>/dev/null || base64 ../agents/reader.py | tr -d '\n')

az deployment sub create \
  --name "cc-testbed-${ENVIRONMENT}-$(date +%s)" \
  --location "$LOCATION" \
  --template-file main.bicep \
  --parameters \
      location="$LOCATION" \
      environment="$ENVIRONMENT" \
      containerImage="$CONTAINER_IMAGE" \
      writerScriptB64="$WRITER_B64" \
      readerScriptB64="$READER_B64"

echo
echo "Deployed scenario: $ENVIRONMENT"
echo "Collect evidence with:"
echo "  az container logs --resource-group rg-cc-sandbox-a --name sandbox-a"
echo "  az container logs --resource-group rg-cc-sandbox-b --name sandbox-b"
