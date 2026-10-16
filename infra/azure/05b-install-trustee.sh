#!/usr/bin/env bash
# Step 5b — Install the REAL Trustee / KBS for end-to-end attestation.
#
# Uses the upstream confidential-containers Trustee chart. If you don't
# have it available you can fall back to the mock from attestation/trustee-mock
# by re-running ../local/install-trustee-mock.sh against this cluster.
set -Eeuo pipefail

echo "[05b] Installing Trustee KBS ..."
kubectl create namespace attestation --dry-run=client -o yaml | kubectl apply -f -

helm repo add trustee https://confidential-containers.github.io/trustee/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

if helm search repo trustee/trustee --version "*" --output json | jq -e '.[0]' >/dev/null 2>&1; then
  helm upgrade --install trustee trustee/trustee \
    --namespace attestation \
    --set rvps.referenceValues."bank-api-clean"=$(sha256sum <(echo bank-api:clean@reference) | awk '{print $1}') \
    --wait --timeout 10m
else
  echo "[05b] Upstream Trustee chart unavailable; deploying mock fallback."
  bash "$(cd "$(dirname "$0")/../local" && pwd)/install-trustee-mock.sh"
fi

kubectl -n attestation get pods
