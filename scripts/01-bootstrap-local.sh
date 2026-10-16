#!/usr/bin/env bash
# Bring up the local kind cluster with Argo CD + Kyverno + Trustee mock.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${KIND_CLUSTER:-secure-gitops-poc}"

banner() { printf "\n\033[1;36m== %s ==\033[0m\n" "$*"; }

banner "1/6 Creating kind cluster $CLUSTER"
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "Cluster already exists, reusing."
else
  kind create cluster --name "$CLUSTER" --config "$ROOT/infra/local/kind-config.yaml"
fi
kubectl cluster-info --context "kind-$CLUSTER"

banner "2/6 Building demo app images (clean + tampered) and loading into kind"
docker build --build-arg IMAGE_VARIANT=clean    -t bank-api:clean    "$ROOT/app"
docker build --build-arg IMAGE_VARIANT=tampered -t bank-api:tampered "$ROOT/app"
kind load docker-image bank-api:clean    --name "$CLUSTER"
kind load docker-image bank-api:tampered --name "$CLUSTER"

banner "3/6 Installing Argo CD"
bash "$ROOT/infra/local/install-argocd.sh"

banner "4/6 Installing Kyverno + ClusterPolicies"
bash "$ROOT/infra/local/install-kyverno.sh"

banner "5/6 Installing trustee-mock + RuntimeClass kata-cc"
bash "$ROOT/infra/local/install-trustee-mock.sh"

banner "6/6 Summary"
kubectl get nodes
kubectl get ns
kubectl get clusterpolicy
echo
echo "Cluster is ready. Next:"
echo "  ./scripts/10-demo1-insecure.sh"
echo "  ./scripts/20-demo2-secure-blocked.sh"
echo "  ./scripts/21-demo2-secure-allowed.sh"
