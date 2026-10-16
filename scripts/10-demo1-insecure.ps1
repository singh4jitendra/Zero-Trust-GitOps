#requires -Version 5.1
<#
.SYNOPSIS  DEMO 1 — Insecure GitOps. Deploys the tampered image with no controls.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
function Banner($m) { Write-Host "`n== $m ==" -ForegroundColor Yellow }
function Pause-Demo {
    if ($env:DEMO_AUTOPLAY) { Write-Host "  [autoplay]" -ForegroundColor DarkGray; Start-Sleep -Seconds 2; return }
    Read-Host "  press <enter> for next step" | Out-Null
}

Banner "Demo 1: 'Normal' GitOps with NO supply-chain or runtime protection"
Write-Host "Deploying bank-api:tampered into the 'bank-insecure' namespace."
Write-Host "No Kyverno policy guards this namespace; no RuntimeClass is enforced."
Pause-Demo

Banner "Applying insecure manifests (simulating Argo CD sync)"
& kubectl apply -f "$root\demo1-insecure\k8s\"
& kubectl -n bank-insecure wait --for=condition=available --timeout=2m deployment/bank-api

Banner "Deployment status — looks 'green' from a GitOps point of view"
& kubectl -n bank-insecure get deploy,pod
Pause-Demo

Banner "But the workload is the TAMPERED image"
$pf = Start-Process -PassThru -NoNewWindow -FilePath kubectl `
    -ArgumentList 'port-forward','-n','bank-insecure','svc/bank-api','18080:80'
try {
    Start-Sleep -Seconds 2
    Write-Host "GET /whoami:"
    & curl.exe -s http://localhost:18080/whoami | & jq .
    Write-Host "`nGET /balance/alice (note 'leaked_key_prefix'):"
    & curl.exe -s http://localhost:18080/balance/alice | & jq .
} finally {
    Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
}
Pause-Demo

Banner "Secret is sitting in plain etcd / readable on the node"
$enc = & kubectl get secret bank-db-key -n bank-insecure -o jsonpath="{.data.db-key}"
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($enc))

Write-Host "`nThe 'Trust Gap' from slide 4: green GitOps + active attack + leaked secret." -ForegroundColor Red
Write-Host "Run .\20-demo2-secure-blocked.ps1 next." -ForegroundColor Cyan
