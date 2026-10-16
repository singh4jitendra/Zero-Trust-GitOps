#!/usr/bin/env bash
# Step 5 — Install Kyverno + apply the verify-image / runtime-class / no-plain-secrets policies.
set -Eeuo pipefail

POLICY_DIR="$(cd "$(dirname "$0")/../../policies/kyverno" && pwd)"

echo "[05] Installing Kyverno ..."
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.2.6 \
  --set admissionController.replicas=2 \
  --wait --timeout 10m

echo "[05] Applying ClusterPolicies from $POLICY_DIR ..."
kubectl apply -f "$POLICY_DIR/"

echo "[05] Active ClusterPolicies:"
kubectl get clusterpolicy
