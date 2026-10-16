#requires -Version 5.1
<#
.SYNOPSIS  DEMO 2b — Legitimate signed image, attestation, secret release.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
$ctx = & kubectl config current-context
$isKind = $ctx -like 'kind-*'

function Banner($m) { Write-Host "`n== $m ==" -ForegroundColor Green }
function Pause-Demo {
    if ($env:DEMO_AUTOPLAY) { Write-Host "  [autoplay]" -ForegroundColor DarkGray; Start-Sleep -Seconds 2; return }
    Read-Host "  press <enter> for next step" | Out-Null
}

Banner "Demo 2b: legitimate CI -> signed image -> attestation -> secret release"
if ($isKind) {
    Write-Host "[LOCAL ONLY] verify-image-cosign -> Audit so locally-built image is admitted." -ForegroundColor Yellow
    & kubectl patch clusterpolicy verify-image-cosign --type=merge `
        -p '{"spec":{"validationFailureAction":"Audit"}}' 2>$null | Out-Null
}
Pause-Demo

Banner "Apply the secure manifests"
& kubectl apply -f "$root\demo2-secure\k8s\runtime-class.yaml"
if ($isKind) {
    & kubectl apply -f "$root\demo2-secure\k8s-kind\deployment-kind.yaml"
} else {
    & kubectl apply -f "$root\demo2-secure\k8s\"
}
& kubectl -n bank-secure rollout status deploy/bank-api --timeout=3m
Pause-Demo

Banner "Init-container log — the attestation handshake"
& kubectl -n bank-secure logs deploy/bank-api -c attestation-agent
Pause-Demo

Banner "Pod admitted, attested, and running"
& kubectl -n bank-secure get pod -o wide
Pause-Demo

Banner "/balance/alice — no leaked secret"
$pf = Start-Process -PassThru -NoNewWindow -FilePath kubectl `
    -ArgumentList 'port-forward','-n','bank-secure','svc/bank-api','28080:80'
try {
    Start-Sleep -Seconds 2
    Write-Host "GET /whoami:"
    & curl.exe -s http://localhost:28080/whoami | & jq .
    Write-Host "`nGET /balance/alice:"
    & curl.exe -s http://localhost:28080/balance/alice | & jq .
} finally {
    Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
}
Pause-Demo

Banner "Trust signals — Prometheus counters from trustee-mock"
$pf2 = Start-Process -PassThru -NoNewWindow -FilePath kubectl `
    -ArgumentList 'port-forward','-n','attestation','svc/trustee-kbs','28081:8080'
try {
    Start-Sleep -Seconds 1
    & curl.exe -s http://localhost:28081/metrics | Select-String '^trustee_' | Sort-Object
} finally {
    Stop-Process -Id $pf2.Id -Force -ErrorAction SilentlyContinue
}

Write-Host "`nDone. The Trust Gap is closed end-to-end." -ForegroundColor Green
