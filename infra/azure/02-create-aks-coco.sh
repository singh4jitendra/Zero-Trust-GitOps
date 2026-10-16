#!/usr/bin/env bash
# Step 2 — AKS cluster with a Confidential Container node pool.
#
# We use the AKS-managed CoCo flow (preview-graduated). The system pool is
# a normal D-series node; the workload pool is Standard_DC4as_cc_v5 which is
# AMD SEV-SNP-capable and labelled so the kata-cc RuntimeClass binds to it.
set -Eeuo pipefail

source "$(dirname "$0")/.env"

AKS="${AKS:-aks-secure-gitops}"
K8S_VERSION="${K8S_VERSION:-1.30}"
SYSTEM_SKU="${SYSTEM_SKU:-Standard_D2s_v5}"
COCO_SKU="${COCO_SKU:-Standard_DC4as_cc_v5}"   # SEV-SNP
COCO_NODES="${COCO_NODES:-2}"

echo "[02] Registering AKS preview features (idempotent) ..."
az feature register --namespace Microsoft.ContainerService --name KataCcIsolationPreview --output none || true
az provider register --namespace Microsoft.ContainerService --output none

echo "[02] Creating AKS cluster $AKS ..."
if ! az aks show -g "$RG" -n "$AKS" --query name -o tsv >/dev/null 2>&1; then
  az aks create \
    --resource-group "$RG" \
    --name "$AKS" \
    --location "$LOCATION" \
    --kubernetes-version "$K8S_VERSION" \
    --node-count 1 \
    --node-vm-size "$SYSTEM_SKU" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-managed-identity \
    --network-plugin azure \
    --network-policy cilium \
    --network-dataplane cilium \
    --generate-ssh-keys \
    --output none
else
  echo "[02] AKS cluster $AKS already exists, skipping create"
fi

echo "[02] Creating CoCo (kata-cc) node pool ..."
if ! az aks nodepool show -g "$RG" --cluster-name "$AKS" -n cocopool --query name -o tsv >/dev/null 2>&1; then
  az aks nodepool add \
    --resource-group "$RG" \
    --cluster-name "$AKS" \
    --name cocopool \
    --node-count "$COCO_NODES" \
    --node-vm-size "$COCO_SKU" \
    --os-sku AzureLinux \
    --workload-runtime KataCcIsolation \
    --node-taints "kata-cc=true:NoSchedule" \
    --labels kubernetes.azure.com/kata-cc-isolation=true \
    --output none
else
  echo "[02] CoCo node pool already exists, skipping"
fi

echo "[02] Fetching kubeconfig ..."
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing

echo "[02] Cluster ready:"
kubectl get nodes -L agentpool,kubernetes.azure.com/kata-cc-isolation
