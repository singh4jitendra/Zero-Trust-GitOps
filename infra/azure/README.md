# Azure Provisioning — AKS with Confidential Containers + ACR + Argo CD

> Runs the **real** Demo 2 path on AMD SEV-SNP hardware via AKS Confidential
> Container node pools. This costs money; tear down after the demo with
> `./99-teardown.sh`.

## What gets created

```
Resource Group:  rg-secure-gitops-poc            (East US by default)
├── ACR:         acrSecureGitOps<random>          (Standard SKU)
├── AKS:         aks-secure-gitops                (1.30, OIDC + workload identity)
│   ├── system node pool (Standard_D2s_v5, 1 node)
│   └── coco-pool   node pool (Standard_DC4as_cc_v5, 2 nodes, kata-cc enabled)
└── Cluster add-ons & workloads:
    ├── kube-system : CoCo runtime + KataCC RuntimeClass
    ├── argocd      : Argo CD                      (helm)
    ├── kyverno     : Kyverno + ClusterPolicies     (helm + apply)
    ├── attestation : Trustee KBS (real, helm)
    └── observability: Prometheus + Grafana w/ Trust SLO dashboard
```

## Prereqs

```bash
az --version           # >= 2.61
az login
az account set --subscription <SUB-ID>
az aks install-cli     # kubectl + kubelogin
helm version           # >= 3.14
```

## Run

```bash
# Variables (edit if you like)
export LOCATION=eastus
export RG=rg-secure-gitops-poc
export AKS=aks-secure-gitops

./01-create-rg-acr.sh
./02-create-aks-coco.sh
./03-attach-acr.sh
./04-install-argocd.sh
./05-install-kyverno.sh
./05b-install-trustee.sh
./06-bootstrap-gitops.sh
./07-install-observability.sh
```

The total time is ~25 minutes. When done you'll get URLs for Argo CD,
Grafana, and the bank-api service.

## Cost

- Standard_DC4as_cc_v5 (the CVM SKU) ≈ ~$0.45 / hr × 2 nodes
- ACR Standard ≈ $0.67 / day
- AKS control plane: free
- LB + egress: trivial for a demo

Round it to **~$1.20 / hour** while the cluster runs.

## Tear-down

```bash
./99-teardown.sh   # az group delete --no-wait
```
