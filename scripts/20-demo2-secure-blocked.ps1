#requires -Version 5.1
<#
.SYNOPSIS  DEMO 2a — Attacker re-runs the exploit against the secure namespace.
           Kyverno's defense-in-depth policies deny admission.

  Three policies guard bank-secure:
    * verify-image-cosign           — requires Sigstore signature (needs registry)
    * require-runtime-class-kata-cc — pod MUST set runtimeClassName: kata-cc
    * disallow-plain-secret-mounts  — no plain k8s Secret volumes allowed
  The first one only fires against real registry images, so in the local kind
  demo the second and third are what visibly block. On AKS with a real ACR
  + signed image, verify-image-cosign blocks first.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
function Banner($m) { Write-Host "`n== $m ==" -ForegroundColor Green }
function Pause-Demo {
    if ($env:DEMO_AUTOPLAY) { Write-Host "  [autoplay]" -ForegroundColor DarkGray; Start-Sleep -Seconds 2; return }
    Read-Host "  press <enter> for next step" | Out-Null
}

Banner "Demo 2a: attacker re-uses the exact Demo 1 manifest against bank-secure"
Write-Host "Three Kyverno ClusterPolicies are in Enforce mode for this namespace:"
& kubectl get clusterpolicy | Select-String -Pattern "verify-image-cosign|require-runtime-class|disallow-plain-secret"
Pause-Demo

Banner "Ensure namespace + RuntimeClass exist"
& kubectl create ns bank-secure --dry-run=client -o yaml | & kubectl apply -f -
& kubectl apply -f "$root\demo2-secure\k8s\runtime-class.yaml" 2>$null

Banner "Construct the SAME attack manifest used in Demo 1 and try to apply it"
$attack = @'
apiVersion: v1
kind: Secret
metadata:
  name: bank-db-key-attack
  namespace: bank-secure
type: Opaque
stringData:
  db-key: "s3cr3tDBkey-DEMO1-leaks-this-to-the-host"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bank-api-attack
  namespace: bank-secure
spec:
  replicas: 1
  selector: { matchLabels: { app: bank-api-attack } }
  template:
    metadata:
      labels: { app: bank-api-attack }
    spec:
      # NOTE: no runtimeClassName -> will be blocked by require-runtime-class-kata-cc
      containers:
        - name: bank-api
          image: bank-api:tampered
          volumeMounts:
            - name: db-key
              mountPath: /etc/secrets
              readOnly: true
      volumes:
        - name: db-key
          secret:
            secretName: bank-db-key-attack   # plain Secret -> blocked by disallow-plain-secret-mounts
'@

$tmp = Join-Path $env:TEMP 'bank-api-tampered-attempt.yaml'
$attack | Out-File -FilePath $tmp -Encoding ascii
Write-Host "+ kubectl apply -f $tmp"
$out = & kubectl apply -f $tmp 2>&1
$out | ForEach-Object { Write-Host $_ }

if ($out -match 'denied the request|blocked due to|validate\.kyverno') {
    Write-Host "`nKyverno denied the deployment. The Trust Gap is closed." -ForegroundColor Green
    Write-Host "Policies that fired (see message above): require-runtime-class-kata-cc and/or disallow-plain-secret-mounts." -ForegroundColor Green
} else {
    Write-Host "`nUnexpected: object was admitted. Current policy state:" -ForegroundColor Yellow
    & kubectl get clusterpolicy
}

Write-Host "`nRun .\21-demo2-secure-allowed.ps1 to see the legitimate flow." -ForegroundColor Cyan
