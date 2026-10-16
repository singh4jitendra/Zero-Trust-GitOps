#!/usr/bin/env bash
# DEMO 2b — Legitimate CI pushes a signed image, attestation succeeds,
# secret is released, /balance works.
#
# Notes for the LOCAL kind demo:
#   - We do NOT actually have a Cosign signature on the locally-built image
#     (it never went through GitHub Actions). To keep the demo flow correct
#     we temporarily relax verify-image-cosign to "Audit" and demonstrate the
#     attestation + secret-release leg, which is the part the laptop CAN do
#     for real. The script labels this clearly with a [LOCAL ONLY] banner.
#   - On AKS, the signature step IS real and this relaxation is skipped.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IS_KIND=0
kubectl config current-context 2>/dev/null | grep -q "kind-" && IS_KIND=1

banner() { printf "\n\033[1;32m== %s ==\033[0m\n" "$*"; }
pause()  { echo; read -r -p "  ↳ press <enter> for next step ..."; }

banner "Demo 2b: legitimate CI -> signed image -> attestation -> secret release"

if [[ "$IS_KIND" -eq 1 ]]; then
  echo "[LOCAL ONLY] Switching verify-image-cosign to Audit so the locally-built"
  echo "[LOCAL ONLY] (unsigned) image is admitted. On AKS this step is skipped."
  kubectl patch clusterpolicy verify-image-cosign --type=merge \
    -p '{"spec":{"validationFailureAction":"Audit"}}' || true
fi
pause

banner "Apply the secure manifests"
kubectl apply -f "$ROOT/demo2-secure/k8s/runtime-class.yaml"
if [[ "$IS_KIND" -eq 1 ]]; then
  # demo2-secure/k8s-kind/deployment-kind.yaml mirrors deployment.yaml but
  # uses the local image + a curl-based init that speaks to trustee-mock.
  kubectl apply -f "$ROOT/demo2-secure/k8s-kind/deployment-kind.yaml"
else
  kubectl apply -f "$ROOT/demo2-secure/k8s/"
fi
kubectl -n bank-secure rollout status deploy/bank-api --timeout=3m
pause

banner "Init-container log — the attestation handshake"
kubectl -n bank-secure logs deploy/bank-api -c attestation-agent || true
pause

banner "The pod admitted, attested, and is running"
kubectl -n bank-secure get pod -o wide
pause

banner "/balance/alice — note 'decrypted_with' fingerprint, no leaked secret"
kubectl -n bank-secure port-forward svc/bank-api 28080:80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID >/dev/null 2>&1 || true' EXIT
sleep 2
curl -s http://localhost:28080/whoami   | jq .
curl -s http://localhost:28080/balance/alice | jq .
pause

banner "Trust signals (slide 12) — Prometheus counters from trustee-mock"
kubectl -n attestation port-forward svc/trustee-kbs 28081:8080 >/dev/null 2>&1 &
PF2=$!
trap 'kill $PF_PID $PF2 >/dev/null 2>&1 || true' EXIT
sleep 1
curl -s http://localhost:28081/metrics | grep -E '^trustee_' | sort

echo
echo "Done. The Trust Gap is closed end-to-end."
