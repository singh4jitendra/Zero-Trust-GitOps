#!/usr/bin/env bash
# Step 1 — Resource group + Azure Container Registry.
# Idempotent: safe to re-run.
set -Eeuo pipefail

LOCATION="${LOCATION:-eastus}"
RG="${RG:-rg-secure-gitops-poc}"
ACR="${ACR:-acrsecuregitops$RANDOM}"
# Persist the chosen ACR name so later scripts pick it up automatically.
ENV_FILE="$(dirname "$0")/.env"

echo "[01] Creating resource group $RG in $LOCATION ..."
az group create --name "$RG" --location "$LOCATION" --output none

# Reuse an existing ACR in the RG if any (so re-runs don't accumulate)
EXISTING=$(az acr list --resource-group "$RG" --query "[?starts_with(name,'acrsecuregitops')].name | [0]" -o tsv || true)
if [[ -n "$EXISTING" ]]; then
  ACR="$EXISTING"
  echo "[01] Reusing existing ACR $ACR"
else
  echo "[01] Creating ACR $ACR ..."
  az acr create --resource-group "$RG" --name "$ACR" --sku Standard --output none
fi

cat > "$ENV_FILE" <<EOF
export LOCATION="$LOCATION"
export RG="$RG"
export ACR="$ACR"
export ACR_LOGIN_SERVER="$(az acr show -n "$ACR" --query loginServer -o tsv)"
EOF

echo "[01] Done. Variables saved to $ENV_FILE"
cat "$ENV_FILE"
