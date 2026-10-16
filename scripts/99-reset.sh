#!/usr/bin/env bash
# Reset between demo runs: deletes the demo namespaces but keeps the
# kind cluster + Argo CD + Kyverno + Trustee mock in place so the next
# run starts in seconds.
set -Eeuo pipefail

echo "[reset] Deleting demo namespaces ..."
kubectl delete ns bank-insecure --ignore-not-found --wait=false
kubectl delete ns bank-secure   --ignore-not-found --wait=false
echo "[reset] Restoring verify-image-cosign to Enforce ..."
kubectl patch clusterpolicy verify-image-cosign --type=merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}' 2>/dev/null || true
echo "[reset] Done."
