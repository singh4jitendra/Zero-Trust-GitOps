#requires -Version 5.1
<#
.SYNOPSIS  Reset demo state between runs (keeps the cluster).
#>
$ErrorActionPreference = 'Continue'
Write-Host "[reset] Deleting demo namespaces ..."
& kubectl delete ns bank-insecure --ignore-not-found --wait=$false 2>$null
& kubectl delete ns bank-secure   --ignore-not-found --wait=$false 2>$null
Write-Host "[reset] Restoring verify-image-cosign to Enforce ..."
& kubectl patch clusterpolicy verify-image-cosign --type=merge `
    -p '{"spec":{"validationFailureAction":"Enforce"}}' 2>$null | Out-Null
Write-Host "[reset] Done." -ForegroundColor Green
