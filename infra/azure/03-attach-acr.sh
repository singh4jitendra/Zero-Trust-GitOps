#!/usr/bin/env bash
# Step 3 — Attach ACR to AKS so the kubelet can pull images via managed identity.
set -Eeuo pipefail
source "$(dirname "$0")/.env"
AKS="${AKS:-aks-secure-gitops}"
echo "[03] Attaching ACR $ACR to AKS $AKS ..."
az aks update -g "$RG" -n "$AKS" --attach-acr "$ACR" --output none
echo "[03] Done."
