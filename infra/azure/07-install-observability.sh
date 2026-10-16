#!/usr/bin/env bash
# Step 7 — kube-prometheus-stack + Trust SLO dashboard import.
set -Eeuo pipefail

DASH="$(cd "$(dirname "$0")/../.." && pwd)/dashboards/grafana-trust-slos.json"

echo "[07] Installing kube-prometheus-stack ..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace observability --create-namespace \
  --set grafana.service.type=LoadBalancer \
  --set grafana.adminPassword='demo-only-NOT-for-prod' \
  --wait --timeout 15m

echo "[07] Importing Trust SLO dashboard ..."
kubectl -n observability create configmap trust-slo-dashboard \
  --from-file=trust-slos.json="$DASH" \
  --dry-run=client -o yaml | \
  kubectl label --local -f - -o yaml grafana_dashboard=1 | \
  kubectl apply -f -

echo "[07] Grafana URL (may take a minute):"
kubectl -n observability get svc kps-grafana \
  -o jsonpath="{.status.loadBalancer.ingress[0].ip}" ; echo
echo "[07] Grafana admin password: demo-only-NOT-for-prod"
