#!/usr/bin/env bash
# Step 4 — Install Argo CD.
set -Eeuo pipefail

echo "[04] Installing Argo CD ..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.6.12 \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=LoadBalancer \
  --wait --timeout 10m

echo "[04] Argo CD installed."
echo "[04] Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d ; echo
echo "[04] Argo CD URL (may take a minute for LB):"
kubectl -n argocd get svc argocd-server -o jsonpath="{.status.loadBalancer.ingress[0].ip}" ; echo
