#requires -Version 5.1
<#
.SYNOPSIS  Bootstrap the local kind cluster with Argo CD + Kyverno + trustee-mock.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
$cluster = if ($env:KIND_CLUSTER) { $env:KIND_CLUSTER } else { 'secure-gitops-poc' }

function Banner($msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }

Banner "1/6 Creating kind cluster $cluster"
$clusters = & kind get clusters 2>$null
if ($clusters -contains $cluster) {
    Write-Host "Cluster exists, reusing."
} else {
    & kind create cluster --name $cluster --config "$root\infra\local\kind-config.yaml"
    if ($LASTEXITCODE -ne 0) { throw "kind create cluster failed" }
}
& kubectl cluster-info --context "kind-$cluster"

Banner "2/6 Building & loading bank-api images (clean + tampered)"
& docker build --build-arg IMAGE_VARIANT=clean    -t bank-api:clean    "$root\app"
& docker build --build-arg IMAGE_VARIANT=tampered -t bank-api:tampered "$root\app"
& kind load docker-image bank-api:clean    --name $cluster
& kind load docker-image bank-api:tampered --name $cluster

Banner "3/6 Installing Argo CD"
& kubectl create namespace argocd --dry-run=client -o yaml | & kubectl apply -f -
& kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.4/manifests/install.yaml
& kubectl -n argocd wait --for=condition=available --timeout=5m deployment/argocd-server
& kubectl -n argocd patch svc argocd-server --type=json `
  -p '[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/0/nodePort","value":30443}]'

$pw = & kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$pwPlain = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($pw))
Write-Host "Argo CD UI: https://localhost:30443  user=admin  password=$pwPlain"

Banner "4/6 Installing Kyverno + ClusterPolicies"
& kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.12.5/install.yaml 2>$null
& kubectl -n kyverno wait --for=condition=available --timeout=5m deployment/kyverno-admission-controller
& kubectl apply -f "$root\policies\kyverno\"
& kubectl get clusterpolicy

Banner "5/6 Installing trustee-mock + RuntimeClass kata-cc"
& docker build -t trustee-mock:0.1.0 "$root\attestation\trustee-mock"
& kind load docker-image trustee-mock:0.1.0 --name $cluster

$runtimeClass = @'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-cc
  labels:
    marker: mock
handler: runc
scheduling:
  nodeSelector:
    kubernetes.azure.com/kata-cc-isolation: "true"
'@
$runtimeClass | & kubectl apply -f -

& kubectl create namespace attestation --dry-run=client -o yaml | & kubectl apply -f -

$trusteeYaml = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trustee-mock
  namespace: attestation
  labels: { app: trustee-mock, marker: mock }
spec:
  replicas: 1
  selector: { matchLabels: { app: trustee-mock } }
  template:
    metadata:
      labels: { app: trustee-mock }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: "/metrics"
        prometheus.io/port: "8080"
    spec:
      containers:
        - name: trustee-mock
          image: trustee-mock:0.1.0
          imagePullPolicy: IfNotPresent
          ports: [{ containerPort: 8080, name: http }]
          env:
            - { name: LISTEN_PORT, value: "8080" }
            - { name: BANK_DB_KEY, value: "TRUSTEE-RELEASED-key-only-after-attestation" }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: trustee-kbs
  namespace: attestation
spec:
  selector: { app: trustee-mock }
  ports: [{ name: http, port: 8080, targetPort: 8080 }]
'@
$trusteeYaml | & kubectl apply -f -
& kubectl -n attestation wait --for=condition=available --timeout=2m deployment/trustee-mock

Banner "6/6 Cluster summary"
& kubectl get nodes
& kubectl get ns
& kubectl get clusterpolicy

Write-Host "`nReady. Next:" -ForegroundColor Green
Write-Host "  .\10-demo1-insecure.ps1"
Write-Host "  .\20-demo2-secure-blocked.ps1"
Write-Host "  .\21-demo2-secure-allowed.ps1"
