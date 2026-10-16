#!/usr/bin/env bash
# Step 6 — Register both demo Applications in Argo CD.
# Edit the repoURL fields in poc/demo*/argocd-application.yaml before running.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "[06] Applying Argo CD Applications ..."
kubectl apply -f "$ROOT/demo1-insecure/argocd-application.yaml"
kubectl apply -f "$ROOT/demo2-secure/argocd-application.yaml"

echo "[06] Sync status:"
kubectl -n argocd get applications
