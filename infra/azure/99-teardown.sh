#!/usr/bin/env bash
# Tear-down — delete the whole resource group asynchronously.
set -Eeuo pipefail
source "$(dirname "$0")/.env" 2>/dev/null || true
RG="${RG:-rg-secure-gitops-poc}"
echo "[99] Deleting resource group $RG (async) ..."
az group delete --name "$RG" --yes --no-wait
echo "[99] Submitted. 'az group show -n $RG' will return 404 in a few minutes."
