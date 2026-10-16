#requires -Version 5.1
<#
.SYNOPSIS
  Provision-only script: builds the Azure infrastructure for the Secure GitOps
  PoC. Does NOT install Argo CD / Kyverno / Trustee / Gitea / Argo apps and
  does NOT run any demo scenes -- those are handled by azure-demo-full.ps1.

  Use this once on a fresh subscription, then on every recording day just run:
      .\azure-demo-full.ps1 -NoProvision

.DESCRIPTION
  Idempotent steps (each one no-ops if already done):
    1. Register Microsoft.ContainerService + KataCcIsolationPreview feature
    2. Create resource group
    3. Create ACR (Standard) + enable anonymous pull
    4. Create AKS 1.33 (2x Standard_D2s_v5 system pool)
    5. Add 'cocopool' (Standard_DC4as_cc_v5, KataCcIsolation, AzureLinux)
    6. Build + push bank-api:clean, bank-api:tampered, trustee-mock:0.1.0

  ~12-18 minutes end-to-end. Costs ~$0.68/hour once running.

.EXAMPLE
  .\azure-provision-infra.ps1
  .\azure-provision-infra.ps1 -SkipImages   # if images already in ACR
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-secure-gitops-poc-ne',
    [string]$Location      = 'northeurope',
    [string]$AksName       = 'aks-secure-gitops',
    [string]$AcrName       = '',
    [string]$CoCoNodeSku   = 'Standard_DC4as_cc_v5',
    [string]$SystemNodeSku = 'Standard_D2s_v5',
    [int]$SystemNodeCount  = 2,
    [string]$K8sVersion    = '1.33',
    [switch]$SkipImages
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path

function Banner($t,$c='Cyan') { Write-Host ''; Write-Host ('=' * 72) -ForegroundColor $c; Write-Host "  $t" -ForegroundColor $c; Write-Host ('=' * 72) -ForegroundColor $c; Write-Host '' }
function Step($m)  { Write-Host ">> $m" -ForegroundColor Yellow }
function Good($m)  { Write-Host "++ $m" -ForegroundColor Green }
function Note($m)  { Write-Host "   $m" -ForegroundColor DarkGray }

Banner 'AZURE INFRASTRUCTURE PROVISIONING (idempotent)' 'Magenta'
$sub = az account show --query 'name' -o tsv
Note "Subscription : $sub"
Note "Resource Grp : $ResourceGroup"
Note "Location     : $Location"
Note "AKS cluster  : $AksName  (K8s $K8sVersion)"
Note "CoCo node    : $CoCoNodeSku"

# -----------------------------------------------------------------------------
Banner 'Step 1/6  Feature flags (one-time per subscription)' 'Cyan'
$state = az feature show --namespace Microsoft.ContainerService --name KataCcIsolationPreview --query 'properties.state' -o tsv 2>$null
if ($state -ne 'Registered') {
    Step "Registering KataCcIsolationPreview (current state: $state)..."
    az feature register --namespace Microsoft.ContainerService --name KataCcIsolationPreview | Out-Null
    Step 'Waiting for Registered (~10 min)...'
    while ((az feature show --namespace Microsoft.ContainerService --name KataCcIsolationPreview --query 'properties.state' -o tsv) -ne 'Registered') {
        Start-Sleep 20; Note '  still registering...'
    }
    az provider register --namespace Microsoft.ContainerService | Out-Null
}
Good 'KataCcIsolationPreview = Registered'

# -----------------------------------------------------------------------------
Banner 'Step 2/6  Resource group' 'Cyan'
if (-not (az group exists --name $ResourceGroup) -eq 'true') {
    Step "Creating $ResourceGroup in $Location"
    az group create --name $ResourceGroup --location $Location -o none
}
Good "Resource group $ResourceGroup ready"

# -----------------------------------------------------------------------------
Banner 'Step 3/6  Azure Container Registry' 'Cyan'
if (-not $AcrName) {
    $AcrName = az acr list -g $ResourceGroup --query "[?starts_with(name,'acrsgpoc')].name | [0]" -o tsv 2>$null
    if (-not $AcrName) {
        $rand = -join ((48..57) + (97..102) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
        $AcrName = "acrsgpoc$rand"
        Step "Creating ACR $AcrName"
        az acr create --name $AcrName --resource-group $ResourceGroup --sku Standard --location $Location -o none
    }
}
Step "Enabling anonymous pull on $AcrName"
az acr update --name $AcrName --anonymous-pull-enabled true -o none
Good "ACR $AcrName ready ($(az acr show -n $AcrName --query loginServer -o tsv))"

# -----------------------------------------------------------------------------
Banner 'Step 4/6  AKS cluster' 'Cyan'
$aksExists = az aks show -g $ResourceGroup -n $AksName --query 'name' -o tsv 2>$null
if (-not $aksExists) {
    # IMPORTANT: aks-preview extension has set_up_network_profile bug; remove before create
    az extension remove --name aks-preview 2>$null | Out-Null
    Step "Creating AKS $AksName (K8s $K8sVersion, ${SystemNodeCount}x $SystemNodeSku)"
    az aks create `
        --resource-group $ResourceGroup --name $AksName `
        --location $Location `
        --kubernetes-version $K8sVersion `
        --node-count $SystemNodeCount --node-vm-size $SystemNodeSku `
        --enable-managed-identity `
        --network-plugin azure `
        --generate-ssh-keys `
        -o none
} else {
    Note "AKS $AksName already exists"
    $sysCount = [int](az aks nodepool show -g $ResourceGroup --cluster-name $AksName -n nodepool1 --query 'count' -o tsv 2>$null)
    if ($sysCount -lt $SystemNodeCount) {
        Step "Scaling system pool from $sysCount to $SystemNodeCount nodes"
        az aks nodepool scale -g $ResourceGroup --cluster-name $AksName -n nodepool1 --node-count $SystemNodeCount -o none
    }
}
Good "AKS $AksName ready"

# -----------------------------------------------------------------------------
Banner 'Step 5/6  Confidential Containers node pool (cocopool)' 'Cyan'
$cocoExists = az aks nodepool show -g $ResourceGroup --cluster-name $AksName -n cocopool --query 'name' -o tsv 2>$null
if (-not $cocoExists) {
    az extension add --name aks-preview --yes 2>$null | Out-Null
    Step "Adding cocopool ($CoCoNodeSku, KataCcIsolation, AzureLinux)"
    az aks nodepool add `
        --resource-group $ResourceGroup --cluster-name $AksName --name cocopool `
        --node-count 1 --node-vm-size $CoCoNodeSku `
        --os-sku AzureLinux --workload-runtime KataCcIsolation `
        --node-taints "kata-cc=true:NoSchedule" `
        -o none
    az extension remove --name aks-preview 2>$null | Out-Null
}
Good 'cocopool ready'

# -----------------------------------------------------------------------------
Banner 'Step 6/6  Container images in ACR' 'Cyan'
if ($SkipImages) {
    Note 'Skipping image build/push (-SkipImages)'
} else {
    $loginServer = az acr show -n $AcrName --query loginServer -o tsv
    Step "Building + pushing images to $loginServer"
    az acr login --name $AcrName -o none

    $images = @(
        @{ tag = 'bank-api:clean';    ctx = "$root\app";                    arg = 'IMAGE_VARIANT=clean' },
        @{ tag = 'bank-api:tampered'; ctx = "$root\app";                    arg = 'IMAGE_VARIANT=tampered' },
        @{ tag = 'trustee-mock:0.1.0'; ctx = "$root\attestation\trustee-mock"; arg = $null }
    )
    foreach ($i in $images) {
        $args = @('build')
        if ($i.arg) { $args += @('--build-arg', $i.arg) }
        $args += @('-t', "$loginServer/$($i.tag)", $i.ctx)
        & docker @args | Out-Null
        & docker push "$loginServer/$($i.tag)" | Select-Object -Last 1
        Note "  + $loginServer/$($i.tag)"
    }
}
Good 'Images ready in ACR'

# -----------------------------------------------------------------------------
Banner 'PROVISIONING COMPLETE' 'Green'
Write-Host @"
You can now run the demo at any time with:

    .\azure-demo-full.ps1 -NoProvision

To tear everything down and drop cost to `$0:

    az group delete --name $ResourceGroup --yes --no-wait
"@ -ForegroundColor White
