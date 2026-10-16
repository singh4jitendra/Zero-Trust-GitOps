#!/usr/bin/env bash
# DEMO 1 — Insecure GitOps. Deploys the TAMPERED image directly
# (no signature check, no admission policy on this namespace).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
banner() { printf "\n\033[1;33m== %s ==\033[0m\n" "$*"; }
pause()  { echo; read -r -p "  ↳ press <enter> for next step ..."; }

banner "Demo 1: 'Normal' GitOps with NO supply-chain or runtime protection"
echo "We will deploy bank-api:tampered into the 'bank-insecure' namespace."
echo "No Kyverno policy guards this namespace and no RuntimeClass is enforced."
pause

banner "Applying the insecure manifests (simulating Argo CD sync)"
kubectl apply -f "$ROOT/demo1-insecure/k8s/"
kubectl -n bank-insecure wait --for=condition=available --timeout=2m deployment/bank-api

banner "The deployment is 'green'"
kubectl -n bank-insecure get deploy,pod
echo
echo "From a GitOps dashboard point of view, everything is fine."
pause

banner "But the workload is the TAMPERED image"
kubectl -n bank-insecure port-forward svc/bank-api 18080:80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID >/dev/null 2>&1 || true' EXIT
sleep 2
echo "GET /whoami:"
curl -s http://localhost:18080/whoami | jq .
echo
echo "GET /balance/alice (notice 'leaked_key_prefix' — the secret has left the pod):"
curl -s http://localhost:18080/balance/alice | jq .
pause

banner "And the secret is sitting in plain etcd / on the node"
echo "kubectl get secret bank-db-key -n bank-insecure -o jsonpath='{.data.db-key}' | base64 -d"
kubectl get secret bank-db-key -n bank-insecure -o jsonpath='{.data.db-key}' | base64 -d ; echo

echo
echo "That is the 'Trust Gap' from slide 4: GitOps green + active attack + leaked secret."
echo "Run ./scripts/20-demo2-secure-blocked.sh next to see the gap closed."
