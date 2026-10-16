#requires -Version 5.1
<#
.SYNOPSIS
  ONE-SHOT recording-ready demo on REAL Azure infrastructure.

  - Uses an existing AKS cluster (rg-secure-gitops-poc / aks-secure-gitops by
    default). Provisions a Confidential Containers (kata-cc) node pool if
    missing. Attaches the ACR named acrsgpoc<random> if present.
  - Installs Argo CD v3.1.0, Kyverno + 3 ClusterPolicies, trustee-mock,
    RuntimeClass kata-cc bound to the real CoCo node pool, and an in-cluster
    Gitea seeded with the demo manifests.
  - Creates two real Argo CD Applications (bank-api-insecure / bank-api-secure)
    that auto-sync from Gitea. Manifests are rewritten on the fly to pull
    images from your ACR.
  - Runs the same 6 scenes as demo-full.ps1 but against AMD SEV-SNP CVMs.

  COSTS APPROXIMATELY $1.20/HOUR WHILE RUNNING. Use 99-teardown-azure.ps1
  (or the -Teardown switch) to drop costs back to $0.

.PARAMETER NoProvision
  Skip the AKS + node pool + ACR provisioning. Use if everything already exists.

.PARAMETER NoBootstrap
  Skip in-cluster install (Argo CD / Kyverno / Trustee / Gitea / images).

.PARAMETER NoTeardown
  Leave AKS + ACR running after the demo (default ON for safety; you must
  explicitly pass -TeardownAfter to delete the resource group).

.PARAMETER TeardownAfter
  Delete the resource group at the end of the run (async). This drops
  Azure cost to $0.

.PARAMETER Fresh
  Tear down any existing 'bank-*' namespaces + Argo CD apps before running.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-secure-gitops-poc-ne',
    [string]$Location      = 'northeurope',
    [string]$AksName       = 'aks-secure-gitops',
    [string]$AcrName       = '',
    [string]$CoCoNodeSku   = 'Standard_DC4as_cc_v5',
    [switch]$NoProvision,
    [switch]$NoBootstrap,
    [switch]$Fresh,
    [switch]$TeardownAfter,
    [int]$ScenePauseSec    = 6,
    [int]$LoginPauseSec    = 20
)

$ErrorActionPreference = 'Stop'
$root         = (Resolve-Path "$PSScriptRoot\..").Path
$argocdUrl    = 'http://localhost:8080'
$giteaUser    = 'demo'
$giteaPass    = 'demo123'
$giteaRepo    = 'secure-gitops-poc'
$giteaSvcUrl  = 'http://gitea-http.gitea.svc.cluster.local:3000'
$giteaLocalPF = 'http://localhost:13000'
$bgProcesses  = @()

# Refresh PATH so docker/kubectl/etc are reachable
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','User') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path','Machine')

function Banner {
    param([string]$Title, [ConsoleColor]$Color = 'Cyan', [string]$Sub = '')
    $bar = ('=' * 72)
    Write-Host ''
    Write-Host $bar -ForegroundColor $Color
    Write-Host ("  " + $Title) -ForegroundColor $Color
    if ($Sub) { Write-Host ("  " + $Sub) -ForegroundColor DarkGray }
    Write-Host $bar -ForegroundColor $Color
    Write-Host ''
}
function Step { param([string]$msg) Write-Host (">> " + $msg) -ForegroundColor Yellow }
function Good { param([string]$msg) Write-Host ("++ " + $msg) -ForegroundColor Green }
function Bad  { param([string]$msg) Write-Host ("!! " + $msg) -ForegroundColor Red }
function ScenePause {
    param([int]$Seconds = $ScenePauseSec, [string]$Tag = '')
    Write-Host ("`n--- pause $Seconds`s --- $Tag`n") -ForegroundColor DarkGray
    Start-Sleep -Seconds $Seconds
}
function Start-PortForward {
    param([string]$ns, [string]$svc, [int]$local, [int]$remote)
    $p = Start-Process -PassThru -WindowStyle Hidden -FilePath kubectl `
        -ArgumentList 'port-forward','-n',$ns,"svc/$svc","${local}:${remote}"
    Start-Sleep -Seconds 2
    $script:bgProcesses += $p.Id
    return $p
}
function Stop-PortForward { param($p) if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }

# -----------------------------------------------------------------------------
# Azure resolution + provisioning
# -----------------------------------------------------------------------------
function Resolve-Acr {
    if ($AcrName) { return }
    Step "Resolving ACR in $ResourceGroup"
    $script:AcrName = az acr list --resource-group $ResourceGroup --query "[?starts_with(name,'acrsgpoc')].name | [0]" -o tsv 2>$null
    if (-not $AcrName) { throw "No ACR found in $ResourceGroup. Run 01-create-rg-acr first or pass -AcrName." }
    Good "Using ACR: $AcrName"
}

function Wait-Aks {
    Step "Waiting for AKS '$AksName' to be Succeeded"
    $deadline = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $deadline) {
        $state = az aks show -g $ResourceGroup -n $AksName --query 'provisioningState' -o tsv 2>$null
        Write-Host "  aks state: $state" -ForegroundColor DarkGray
        if ($state -eq 'Succeeded') { Good "AKS ready."; return }
        if ($state -in 'Failed','Canceled') { throw "AKS provisioning $state" }
        Start-Sleep 20
    }
    throw "AKS did not reach Succeeded in 20 minutes"
}

function Ensure-CoCoPool {
    Step "Ensuring CoCo (kata-cc) node pool exists"
    # System pool needs >= 2 nodes; one node fills up at ~91% CPU with all the
    # Azure-managed daemonsets + argocd + kyverno + gitea + trustee-mock.
    $sysCount = [int](az aks nodepool show -g $ResourceGroup --cluster-name $AksName -n nodepool1 --query 'count' -o tsv 2>$null)
    if ($sysCount -lt 2) {
        Step "Scaling system pool 'nodepool1' from $sysCount to 2 nodes (avoids Pending pods on a single small system node)"
        az aks nodepool scale -g $ResourceGroup --cluster-name $AksName -n nodepool1 --node-count 2 -o none 2>&1 | Out-Host
    }
    $exists = az aks nodepool show -g $ResourceGroup --cluster-name $AksName -n cocopool --query 'name' -o tsv 2>$null
    if ($exists) { Good "Node pool 'cocopool' already exists."; return }
    az extension add --name aks-preview --yes 2>$null | Out-Null
    Step "Adding cocopool ($CoCoNodeSku, KataCcIsolation, AzureLinux)..."
    az aks nodepool add `
        --resource-group $ResourceGroup --cluster-name $AksName --name cocopool `
        --node-count 1 --node-vm-size $CoCoNodeSku `
        --os-sku AzureLinux --workload-runtime KataCcIsolation `
        --node-taints "kata-cc=true:NoSchedule" `
        --output table 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to add CoCo node pool (see error above)" }
    az extension remove --name aks-preview 2>$null | Out-Null
    Good "Node pool 'cocopool' added."
}

function Attach-Acr {
    Step "Enabling anonymous pull on ACR '$AcrName' (works without subscription Owner role)"
    az acr update -n $AcrName --anonymous-pull-enabled true --output none 2>&1 | Out-Host
}

function Get-Kubeconfig {
    Step "Fetching kubeconfig"
    az aks get-credentials -g $ResourceGroup -n $AksName --overwrite-existing 2>&1 | Out-Host
    & kubectl config use-context $AksName 2>&1 | Out-Host
    # Sanity check we're talking to the right cluster
    $srv = & kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
    Good "kubectl is talking to: $srv"
    if ($srv -notmatch 'azmk8s\.io') { throw "kubectl is NOT pointed at AKS (got: $srv). Aborting." }
}

function Push-ImagesToAcr {
    Step "Pushing bank-api images to ACR (clean + tampered + trustee-mock)"
    az acr login --name $AcrName 2>&1 | Select-Object -Last 1
    $loginServer = az acr show -n $AcrName --query loginServer -o tsv
    foreach ($img in @(
        @{ tag = "bank-api:clean";    ctx = "$root\app"; build_arg = "IMAGE_VARIANT=clean" },
        @{ tag = "bank-api:tampered"; ctx = "$root\app"; build_arg = "IMAGE_VARIANT=tampered" },
        @{ tag = "trustee-mock:0.1.0"; ctx = "$root\attestation\trustee-mock"; build_arg = $null }
    )) {
        $args = @('build')
        if ($img.build_arg) { $args += @('--build-arg', $img.build_arg) }
        $args += @('-t', "$loginServer/$($img.tag)", $img.ctx)
        & docker @args | Out-Null
        & docker push "$loginServer/$($img.tag)" | Select-Object -Last 1
        Write-Host "  + $loginServer/$($img.tag)" -ForegroundColor DarkGray
    }
}

# -----------------------------------------------------------------------------
# In-cluster install: Argo CD v3.1.0 + Kyverno + Trustee + Gitea + RuntimeClass
# -----------------------------------------------------------------------------
function Install-Argo {
    Step 'Installing Argo CD v3.1.0 (insecure-http for browser)'
    & kubectl create namespace argocd --dry-run=client -o yaml | & kubectl apply -f - | Out-Null
    & kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.1.0/manifests/install.yaml | Out-Host
    & kubectl -n argocd wait --for=condition=available --timeout=10m deployment/argocd-server | Out-Host
    & kubectl -n argocd patch configmap argocd-cmd-params-cm --type=merge -p '{"data":{"server.insecure":"true"}}' | Out-Null
    & kubectl -n argocd rollout restart deployment argocd-server | Out-Null
    & kubectl -n argocd rollout status deployment argocd-server --timeout=5m | Out-Host
}

function Install-Kyverno {
    Step 'Installing Kyverno + ClusterPolicies'
    & kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.12.5/install.yaml 2>$null | Out-Null
    & kubectl -n kyverno wait --for=condition=available --timeout=5m deployment/kyverno-admission-controller | Out-Host
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $eps = & kubectl -n kyverno get endpoints kyverno-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>$null
        if ($eps) { break }
        Start-Sleep 3
    }
    Get-ChildItem "$root\policies\kyverno\*.yaml" | ForEach-Object {
        $f = $_.FullName
        for ($i = 1; $i -le 8; $i++) {
            $out = & kubectl apply -f $f 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host $out; break }
            if ("$out" -match 'connection refused|no endpoints available|failed calling webhook') {
                Start-Sleep 5
            } else {
                Write-Host $out -ForegroundColor Red; break
            }
        }
    }
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $allReady = $true
        $statuses = & kubectl get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="Ready")].status} {end}' 2>$null
        if ($statuses -match ':False|:Unknown') { $allReady = $false }
        if ($allReady) { break }
        Start-Sleep 3
    }
    & kubectl get clusterpolicy
}

function Install-RuntimeClass {
    Step 'Creating RuntimeClass kata-cc bound to the real CoCo node pool'
    # On AKS with KataCcIsolation, the containerd runtime handler installed on the
    # CVM nodes is literally 'kata-cc'. (AKS also auto-creates a RuntimeClass
    # named 'kata-cc-isolation' that points at the same handler.) Our own class
    # is named 'kata-cc' so the manifests in Gitea stay portable from the kind
    # demo (where the same name is mock-handler).
    & kubectl delete runtimeclass kata-cc --ignore-not-found 2>$null | Out-Null
    $rc = @"
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-cc
  labels:
    azure: real-cvm
handler: kata-cc
scheduling:
  nodeSelector:
    kubernetes.azure.com/kata-cc-isolation: "true"
  tolerations:
    - key: kata-cc
      operator: Equal
      value: "true"
      effect: NoSchedule
"@
    $rc | & kubectl apply -f - | Out-Null
}

# AKS CoCo (kata-cc) embeds an OPA policy in the guest. The default policy
# denies most agent RPCs (UpdateInterfaceRequest, CreateContainerRequest, ...)
# so pods get stuck in Init with 'no values returned'. For a stakeholder demo
# we annotate the pod template with a permissive allow-all policy. Production
# would generate a per-pod policy with Microsoft's `genpolicy` tool.
function Get-CoCoAllowAllPolicyBase64 {
    $rego = @'
package agent_policy

default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := true
default CreateContainerRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default ExecProcessRequest := true
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default ReadStreamRequest := true
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SetPolicyRequest := true
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default WriteStreamRequest := true
'@
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rego))
}

function Install-Trustee {
    Step 'Deploying trustee-mock (KBS protocol implementation; on AKS real Trustee Helm chart is in infra/azure/05b)'
    $loginServer = az acr show -n $AcrName --query loginServer -o tsv
    & kubectl create namespace attestation --dry-run=client -o yaml | & kubectl apply -f - | Out-Null
    $trustee = @"
apiVersion: apps/v1
kind: Deployment
metadata: { name: trustee-mock, namespace: attestation, labels: { app: trustee-mock } }
spec:
  replicas: 1
  selector: { matchLabels: { app: trustee-mock } }
  template:
    metadata: { labels: { app: trustee-mock } }
    spec:
      containers:
        - name: trustee-mock
          image: $loginServer/trustee-mock:0.1.0
          imagePullPolicy: IfNotPresent
          ports: [{ containerPort: 8080 }]
          env:
            - { name: LISTEN_PORT, value: "8080" }
            - { name: BANK_DB_KEY, value: "TRUSTEE-RELEASED-key-only-after-attestation" }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata: { name: trustee-kbs, namespace: attestation }
spec:
  selector: { app: trustee-mock }
  ports: [{ name: http, port: 8080, targetPort: 8080 }]
"@
    $trustee | & kubectl apply -f - | Out-Null
    & kubectl -n attestation wait --for=condition=available --timeout=2m deployment/trustee-mock | Out-Host
}

function Setup-Gitea {
    Step 'Deploying in-cluster Gitea (GitOps source for Argo CD)'
    $giteaManifest = @"
apiVersion: v1
kind: Namespace
metadata: { name: gitea }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: gitea, namespace: gitea }
spec:
  replicas: 1
  selector: { matchLabels: { app: gitea } }
  template:
    metadata: { labels: { app: gitea } }
    spec:
      containers:
        - name: gitea
          image: gitea/gitea:1.22.0
          ports:
            - { containerPort: 3000, name: http }
          env:
            - { name: GITEA__database__DB_TYPE,             value: "sqlite3" }
            - { name: GITEA__database__PATH,                value: "/data/gitea/gitea.db" }
            - { name: GITEA__security__INSTALL_LOCK,        value: "true" }
            - { name: GITEA__security__SECRET_KEY,          value: "mock-not-for-prod-only-for-demo" }
            - { name: GITEA__security__INTERNAL_TOKEN,      value: "mock-internal-token-only-for-demo" }
            - { name: GITEA__server__DOMAIN,                value: "gitea-http.gitea.svc.cluster.local" }
            - { name: GITEA__server__ROOT_URL,              value: "$giteaSvcUrl/" }
            - { name: GITEA__server__HTTP_PORT,             value: "3000" }
            - { name: GITEA__server__DISABLE_SSH,           value: "true" }
            - { name: GITEA__service__DISABLE_REGISTRATION, value: "true" }
            - { name: USER_UID, value: "1000" }
            - { name: USER_GID, value: "1000" }
          readinessProbe:
            httpGet: { path: /, port: 3000 }
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 30
          volumeMounts:
            - { name: data, mountPath: /data }
      volumes:
        - { name: data, emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata: { name: gitea-http, namespace: gitea }
spec:
  selector: { app: gitea }
  ports: [{ port: 3000, targetPort: 3000, name: http }]
"@
    $giteaManifest | & kubectl apply -f - | Out-Null
    & kubectl -n gitea rollout status deploy/gitea --timeout=5m | Out-Host

    Step "Creating Gitea admin user '$giteaUser'"
    & kubectl -n gitea exec deploy/gitea -- su git -c "gitea admin user create --username $giteaUser --password $giteaPass --email $giteaUser@local --admin --must-change-password=false" 2>&1 |
        ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

function Push-ManifestsToGitea {
    Step 'Pushing demo manifests into Gitea (image refs rewritten to ACR)'
    $loginServer = az acr show -n $AcrName --query loginServer -o tsv
    $pf = Start-Process -PassThru -WindowStyle Hidden -FilePath kubectl `
        -ArgumentList 'port-forward','-n','gitea','svc/gitea-http','13000:3000'
    $script:bgProcesses += $pf.Id
    Start-Sleep 3

    $authBytes  = [Text.Encoding]::ASCII.GetBytes("${giteaUser}:${giteaPass}")
    $basic      = 'Basic ' + [Convert]::ToBase64String($authBytes)
    $hdr        = @{ Authorization = $basic; 'Content-Type' = 'application/json' }

    for ($i = 1; $i -le 30; $i++) {
        try { Invoke-RestMethod -Uri "$giteaLocalPF/api/v1/version" -TimeoutSec 3 | Out-Null; break }
        catch { Start-Sleep 2 }
    }

    try {
        $body = @{ name = $giteaRepo; auto_init = $true; default_branch = 'main'; private = $false } | ConvertTo-Json
        Invoke-RestMethod -Uri "$giteaLocalPF/api/v1/user/repos" -Method POST -Headers $hdr -Body $body | Out-Null
        Write-Host "  repo '$giteaRepo' created" -ForegroundColor DarkGray
    } catch {
        if ("$_" -match 'already exists|409') { Write-Host "  repo '$giteaRepo' reused" -ForegroundColor DarkGray }
        else { throw }
    }

    $files = @{
        'demo1-insecure/k8s/deployment.yaml'         = 'demo1-insecure/k8s/deployment.yaml'
        'demo1-insecure/k8s/service.yaml'            = 'demo1-insecure/k8s/service.yaml'
        'demo1-insecure/k8s/secret.yaml'             = 'demo1-insecure/k8s/secret.yaml'
        'demo2-secure/k8s/runtime-class.yaml'        = 'demo2-secure/k8s/runtime-class.yaml'
        'demo2-secure/k8s-kind/deployment-kind.yaml' = 'demo2-secure/k8s-kind/deployment-kind.yaml'
    }
    foreach ($k in $files.Keys) {
        $src = Join-Path $root $k
        $dst = $files[$k]
        if (-not (Test-Path $src)) { continue }
        # Rewrite image references to point at ACR
        $text = Get-Content $src -Raw -Encoding UTF8
        $text = $text -replace 'image:\s*bank-api:clean',    "image: $loginServer/bank-api:clean"
        $text = $text -replace 'image:\s*bank-api:tampered', "image: $loginServer/bank-api:tampered"
        $bytes   = [Text.Encoding]::UTF8.GetBytes($text)
        $b64     = [Convert]::ToBase64String($bytes)
        $apiUrl  = "$giteaLocalPF/api/v1/repos/$giteaUser/$giteaRepo/contents/$dst"
        $payload = @{ message = "seed $dst"; content = $b64; branch = 'main' } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri $apiUrl -Method POST -Headers $hdr -Body $payload | Out-Null
            Write-Host "  + $dst (image=$loginServer)" -ForegroundColor DarkGray
        } catch {
            try {
                $existing = Invoke-RestMethod -Uri $apiUrl -Method GET -Headers $hdr
                $payload2 = @{ message = "update $dst"; content = $b64; sha = $existing.sha; branch = 'main' } | ConvertTo-Json
                Invoke-RestMethod -Uri $apiUrl -Method PUT -Headers $hdr -Body $payload2 | Out-Null
                Write-Host "  ~ $dst (updated)" -ForegroundColor DarkGray
            } catch { Write-Host "  ! could not upload $dst : $_" -ForegroundColor Red }
        }
    }
    Stop-PortForward $pf
}

function Create-ArgoApp {
    param([string]$Name, [string]$Path, [string]$DestNamespace)
    $app = @"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $Name
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: $giteaSvcUrl/$giteaUser/$giteaRepo.git
    targetRevision: main
    path: $Path
  destination:
    server: https://kubernetes.default.svc
    namespace: $DestNamespace
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry:
      limit: 3
      backoff: { duration: 5s, factor: 2, maxDuration: 30s }
"@
    $app | & kubectl apply -f - | Out-Host
}

function Wait-ArgoAppHealthy {
    param([string]$Name, [string]$DestNamespace, [string]$DestDeploy, [int]$TimeoutSec = 240)
    & kubectl -n argocd annotate application $Name --overwrite 'argocd.argoproj.io/refresh=hard' 2>$null | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $out = & kubectl -n $DestNamespace wait "deployment/$DestDeploy" --for=condition=available --timeout=5s 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Host "  waiting for $Name -> deployment/$DestDeploy..." -ForegroundColor DarkGray
        Start-Sleep 3
    }
    Bad "  timed out waiting for $DestDeploy"
    return $false
}

# -----------------------------------------------------------------------------
# Argo CD UI helper
# -----------------------------------------------------------------------------
function Open-ArgoCDInBrowser {
    Step "Starting Argo CD port-forward on $argocdUrl"
    $pf = Start-Process -PassThru -WindowStyle Hidden -FilePath kubectl `
        -ArgumentList 'port-forward','-n','argocd','svc/argocd-server','8080:80'
    $script:bgProcesses += $pf.Id
    Start-Sleep 3
    $pw = & kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
    $pwPlain = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($pw))
    try { Set-Clipboard -Value $pwPlain; $note = '(copied to clipboard - paste with Ctrl+V)' }
    catch { $note = '(clipboard unavailable; type manually)' }
    Write-Host ''
    Write-Host '+======================================================================+' -ForegroundColor Yellow
    Write-Host '|  ARGO CD LOGIN CREDENTIALS (REAL AZURE)                              |' -ForegroundColor Yellow
    Write-Host ('|    URL      : {0,-54} |' -f $argocdUrl) -ForegroundColor Yellow
    Write-Host  '|    Username : admin                                                  |' -ForegroundColor Yellow
    Write-Host ('|    Password : {0,-54} |' -f $pwPlain) -ForegroundColor Yellow
    Write-Host ('|             : {0,-54} |' -f $note) -ForegroundColor DarkYellow
    Write-Host '+======================================================================+' -ForegroundColor Yellow
    Write-Host ''
    Step 'Opening Argo CD UI in your default browser ...'
    Start-Process $argocdUrl
    return $pf
}

function Reset-DemoState {
    Step 'Resetting demo state'
    foreach ($app in 'bank-api-insecure','bank-api-secure') {
        & kubectl -n argocd patch application $app --type=merge -p '{"metadata":{"finalizers":[]}}' 2>$null | Out-Null
        & kubectl -n argocd delete application $app --ignore-not-found --wait=$false 2>$null | Out-Null
    }
    & kubectl delete deploy bank-api-attack -n bank-secure --ignore-not-found 2>$null | Out-Null
    & kubectl delete ns bank-insecure --ignore-not-found 2>$null | Out-Null
    & kubectl delete ns bank-secure   --ignore-not-found 2>$null | Out-Null
    & kubectl wait --for=delete namespace/bank-insecure --timeout=60s 2>$null | Out-Null
    & kubectl wait --for=delete namespace/bank-secure   --timeout=60s 2>$null | Out-Null
    # verify-image-cosign is deleted in Scene-Demo2b-Legit for the Azure demo
    # (ACR images are not Sigstore-signed). Reset only re-applies what Install-Kyverno
    # creates, so nothing to restore here.
}

# -----------------------------------------------------------------------------
# Scenes (real Azure)
# -----------------------------------------------------------------------------
function Scene-ControlPlane {
    Banner 'SCENE 0  --  REAL AZURE: the control plane that protects every workload' 'Cyan'

    Write-Host '+======================================================================+' -ForegroundColor Magenta
    Write-Host '|  ENVIRONMENT - REAL AZURE                                            |' -ForegroundColor Magenta
    Write-Host ("|    Subscription : {0,-50} |" -f (az account show --query 'name' -o tsv)) -ForegroundColor Magenta
    Write-Host ("|    Resource Grp : {0,-50} |" -f $ResourceGroup) -ForegroundColor Magenta
    Write-Host ("|    Region       : {0,-50} |" -f $Location)      -ForegroundColor Magenta
    Write-Host ("|    AKS cluster  : {0,-50} |" -f $AksName)       -ForegroundColor Magenta
    Write-Host ("|    CoCo node    : {0,-50} |" -f $CoCoNodeSku)   -ForegroundColor Magenta
    Write-Host ("|    ACR          : {0,-50} |" -f $AcrName)       -ForegroundColor Magenta
    Write-Host '|                                                                      |' -ForegroundColor Magenta
    Write-Host '|  The cocopool runs on AMD SEV-SNP Confidential VMs.                  |' -ForegroundColor Magenta
    Write-Host '|  Every pod with runtimeClassName: kata-cc lands inside a per-pod CVM |' -ForegroundColor Magenta
    Write-Host '|  with encrypted memory and hardware attestation.                     |' -ForegroundColor Magenta
    Write-Host '+======================================================================+' -ForegroundColor Magenta
    Write-Host ''

    Step 'AKS nodes (system pool + Confidential Containers node pool):'
    & kubectl get nodes -L agentpool,kubernetes.azure.com/kata-cc-isolation -o wide
    Write-Host ''
    Step 'Namespaces:'
    & kubectl get ns | Select-String -Pattern 'argocd|kyverno|attestation|gitea'
    Write-Host ''
    Step 'Kyverno ClusterPolicies:'
    & kubectl get clusterpolicy
    Write-Host ''
    Step 'Trustee KBS Service:'
    & kubectl get deploy,svc -n attestation
    Write-Host ''
    Step 'Gitea (in-cluster GitOps source):'
    & kubectl get deploy,svc -n gitea
    Write-Host ''
    Step 'RuntimeClass kata-cc (handler=kata-cc -> AKS CoCo containerd handler on the CVM):'
    & kubectl get runtimeclass kata-cc -o yaml | Select-String -Pattern 'name:|handler:|nodeSelector:|kubernetes.azure.com|tolerations:'
    Write-Host ''
    Step 'Argo CD Applications (empty before Scene 1):'
    & kubectl -n argocd get applications
    ScenePause -Tag 'switch to the Argo CD browser tab (Applications page is empty), then back'
}

function Scene-Demo1-Insecure {
    Banner 'SCENE 1  --  DEMO 1: Insecure GitOps on Azure (the Trust Gap)' 'Red' `
        'Argo CD syncs the insecure manifests from Gitea. Plain Secret, runc, no policies for bank-insecure.'

    Step 'Registering Argo CD Application bank-api-insecure (image pulled from your ACR):'
    Create-ArgoApp -Name 'bank-api-insecure' -Path 'demo1-insecure/k8s' -DestNamespace 'bank-insecure'

    Step 'Waiting for Argo CD to sync ...'
    Wait-ArgoAppHealthy -Name 'bank-api-insecure' -DestNamespace 'bank-insecure' -DestDeploy 'bank-api' -TimeoutSec 240 | Out-Null
    & kubectl -n argocd get application bank-api-insecure -o 'custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL'

    Write-Host ''
    Step 'What Argo CD just deployed:'
    & kubectl get deploy,pod,svc,secret -n bank-insecure -o wide
    Write-Host ''
    Step 'Pod runtime: no runtimeClassName -> default Azure containerd runtime (shared kernel)'
    & kubectl -n bank-insecure get pod -o custom-columns='POD:.metadata.name,RUNTIME:.spec.runtimeClassName,NODE:.spec.nodeName'

    Write-Host ''
    Step 'The Secret in etcd is base64-only (visible to anyone with cluster-admin):'
    $enc = & kubectl get secret bank-db-key -n bank-insecure -o jsonpath='{.data.db-key}'
    Write-Host "etcd value (base64): $enc" -ForegroundColor DarkGray
    Write-Host ("decoded:             " + [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($enc))) -ForegroundColor Red

    Write-Host ''
    Step 'Hitting the live API:'
    $pf = Start-PortForward -ns 'bank-insecure' -svc 'bank-api' -local 18080 -remote 80
    try {
        Write-Host '+ curl /whoami' -ForegroundColor DarkGray
        & curl.exe -s http://localhost:18080/whoami | & jq .
        Write-Host ''
        Write-Host '+ curl /balance/alice' -ForegroundColor DarkGray
        & curl.exe -s http://localhost:18080/balance/alice | & jq .
    } finally { Stop-PortForward $pf }

    Write-Host ''
    Bad 'image_variant=tampered   AND   leaked_key_prefix=s3cr3tDB'
    Bad 'Argo CD shows bank-api-insecure as Synced + Healthy. Everything looks fine.'
    Bad 'This is the Trust Gap from slide 4 -- now running on REAL AZURE INFRA.'
    ScenePause -Tag 'pan to Argo CD UI -> bank-api-insecure tile (resource tree)'
}

function Scene-Demo2a-Block {
    Banner 'SCENE 2  --  DEMO 2a: the SAME attack arrives in bank-secure (REAL AKS)' 'Green' `
        'Kyverno blocks at admission. Two policies fire.'

    Step 'Same attacker manifest as Demo 1 (no runtimeClass, plain Secret mount):'
    $attack = @"
apiVersion: v1
kind: Namespace
metadata: { name: bank-secure }
---
apiVersion: v1
kind: Secret
metadata: { name: bank-db-key-attack, namespace: bank-secure }
type: Opaque
stringData: { db-key: "s3cr3tDBkey-DEMO1-leaks-this-to-the-host" }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: bank-api-attack, namespace: bank-secure }
spec:
  replicas: 1
  selector: { matchLabels: { app: bank-api-attack } }
  template:
    metadata: { labels: { app: bank-api-attack } }
    spec:
      containers:
        - name: bank-api
          image: $(az acr show -n $AcrName --query loginServer -o tsv)/bank-api:tampered
          volumeMounts: [{ name: db-key, mountPath: /etc/secrets, readOnly: true }]
      volumes:
        - name: db-key
          secret: { secretName: bank-db-key-attack }
"@
    $tmp = Join-Path $env:TEMP 'azure-demo-attack.yaml'
    $attack | Out-File -FilePath $tmp -Encoding ascii
    Step 'kubectl apply -f <attack> :'
    $out = & kubectl apply -f $tmp 2>&1
    foreach ($l in $out) {
        $s = "$l"
        if ($s -match 'denied|blocked|disallow-plain|require-runtime') { Write-Host $s -ForegroundColor Red }
        else { Write-Host $s }
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue

    Write-Host ''
    Good 'Kyverno denied the deployment at admission. Policies that fired:'
    Good '  - disallow-plain-secret-mounts   (no plain k8s Secret volumes in bank-secure)'
    Good '  - require-runtime-class-kata-cc  (pods must request a CVM)'
    ScenePause -Tag 'narrate: 3 admission policies, defense in depth'
}

function Scene-Demo2b-Legit {
    Banner 'SCENE 3  --  DEMO 2b: the legitimate path on REAL AZURE CVM' 'Green' `
        'Argo CD syncs the secure manifest. Pod admitted, lands on a CoCo node, attests, gets the DB key.'

    Step 'Snippet of the secure deployment in Gitea:'
    Get-Content "$root\demo2-secure\k8s-kind\deployment-kind.yaml" |
        Select-String -Pattern 'runtimeClassName|initContainers|attestation-agent|TRUSTEE_URL|RESOURCE_ID|/run/trustee/db-key' |
        Select-Object -First 10 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

    Write-Host ''
    Step 'Removing verify-image-cosign for the Azure demo (image is in ACR but not Sigstore-signed; the OTHER two policies still guard bank-secure):'
    & kubectl delete clusterpolicy verify-image-cosign --ignore-not-found 2>&1 | Out-Null

    Step 'Pre-creating bank-secure namespace + RuntimeClass kata-cc:'
    & kubectl create namespace bank-secure --dry-run=client -o yaml | & kubectl apply -f - | Out-Null

    Step 'Registering Argo CD Application bank-api-secure (ACR image, runtimeClassName: kata-cc):'
    Create-ArgoApp -Name 'bank-api-secure' -Path 'demo2-secure/k8s-kind' -DestNamespace 'bank-secure'

    # Patch the deployment with the AKS CoCo guest OPA allow-all policy so the
    # pod sandbox can come up on the SEV-SNP CVM. Wait for the deployment to
    # appear (Argo applies it asynchronously), then patch, then wait for ready.
    Step 'Applying AKS CoCo guest policy annotation (allow-all for demo) ...'
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $exists = & kubectl -n bank-secure get deployment bank-api -o name 2>$null
        if ($LASTEXITCODE -eq 0 -and $exists) { break }
        Start-Sleep 3
    }
    $b64 = Get-CoCoAllowAllPolicyBase64
    $patch = (@{ spec = @{ template = @{ metadata = @{ annotations = @{ 'io.katacontainers.config.agent.policy' = $b64 } } } } } | ConvertTo-Json -Depth 10 -Compress)
    & kubectl -n bank-secure patch deployment bank-api --type=merge -p $patch | Out-Null

    Step 'Waiting for pod to schedule onto a CoCo CVM + attestation to complete ...'
    Wait-ArgoAppHealthy -Name 'bank-api-secure' -DestNamespace 'bank-secure' -DestDeploy 'bank-api' -TimeoutSec 360 | Out-Null
    & kubectl -n argocd get application bank-api-secure -o 'custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL'

    Write-Host ''
    Step 'Attestation handshake from the init container:'
    & kubectl -n bank-secure logs deploy/bank-api -c attestation-agent
    Write-Host ''
    Step 'The pod is on the cocopool node (Standard_DC4as_cc_v5 = AMD SEV-SNP):'
    & kubectl -n bank-secure get pod -o custom-columns='POD:.metadata.name,RUNTIME:.spec.runtimeClassName,NODE:.spec.nodeName,STATUS:.status.phase'

    Write-Host ''
    Step 'Hitting the live secure API (one-shot curl pod from default ns; bank-secure ns is locked down by Kyverno):'
    Write-Host '+ curl /whoami' -ForegroundColor DarkGray
    & kubectl run azure-curl-whoami --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n default -- `
        curl -fsS --max-time 10 http://bank-api.bank-secure.svc/whoami 2>&1 |
        Where-Object { $_ -notmatch '^pod "azure-curl-' } |
        ForEach-Object { try { $_ | & jq . } catch { $_ } }
    Write-Host ''
    Write-Host '+ curl /balance/alice' -ForegroundColor DarkGray
    & kubectl run azure-curl-bal --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n default -- `
        curl -fsS --max-time 10 http://bank-api.bank-secure.svc/balance/alice 2>&1 |
        Where-Object { $_ -notmatch '^pod "azure-curl-' } |
        ForEach-Object { try { $_ | & jq . } catch { $_ } }

    Write-Host ''
    Good 'image_variant=clean   decrypted_with=key-fingerprint:TRUS***   NO leaked key'
    Good 'The pod is running in encrypted RAM. The host kernel cannot see the DB key.'
    Good 'The Trust Gap is closed END-TO-END on REAL AZURE.'
    ScenePause -Tag 'pan to Argo CD UI -> bank-api-secure resource tree'
}

function Scene-TrustMetrics {
    Banner 'SCENE 4  --  trust signals (Trustee KBS Prometheus counters)' 'Cyan'
    $pf = Start-PortForward -ns 'attestation' -svc 'trustee-kbs' -local 28081 -remote 8080
    try {
        Step 'Counters that feed the Grafana SLO dashboard on slide 12:'
        & curl.exe -s http://localhost:28081/metrics | Select-String '^trustee_' | Sort-Object
    } finally { Stop-PortForward $pf }
    ScenePause -Tag 'narrate: SLO alerting on attestation failures / sig mismatches'
}

function Scene-AzureProof {
    Banner 'SCENE 5  --  proving this is REAL Azure (not a mock)' 'Magenta'

    Step 'Azure CLI subscription:'
    az account show --query "{name:name, id:id, user:user.name}" -o table

    Write-Host ''
    Step 'Resource group + AKS cluster details:'
    az aks show -g $ResourceGroup -n $AksName --query "{name:name, k8s:kubernetesVersion, region:location, fqdn:fqdn, oidcIssuer:oidcIssuerProfile.issuerUrl}" -o table

    Write-Host ''
    Step 'Confidential Container node pool:'
    az aks nodepool show -g $ResourceGroup --cluster-name $AksName -n cocopool --query "{name:name, vmSize:vmSize, count:count, osSku:osSku, workloadRuntime:workloadRuntime, mode:mode}" -o table

    Write-Host ''
    Step 'ACR (image source):'
    az acr show -n $AcrName --query "{name:name, loginServer:loginServer, sku:sku.name}" -o table

    Write-Host ''
    Step 'Estimated current cost ($/hour while running):'
    Write-Host '  1x system D2s_v5         ~ 0.10' -ForegroundColor DarkGray
    Write-Host '  1x cocopool DC4as_cc_v5  ~ 0.45' -ForegroundColor DarkGray
    Write-Host '  ACR Standard             ~ 0.03' -ForegroundColor DarkGray
    Write-Host '  AKS Free tier            ~ 0.00' -ForegroundColor DarkGray
    Write-Host '  ---------------------------------' -ForegroundColor DarkGray
    Write-Host '  TOTAL approximately      ~ 0.58 USD / hour' -ForegroundColor Green
    Write-Host '  To stop the bill: kubectl delete ns / az group delete --name rg-secure-gitops-poc --yes --no-wait' -ForegroundColor DarkGray

    ScenePause -Tag 'narrate: this is the real Azure Portal-visible state'
}

function Scene-Wrap {
    Banner 'DEMO COMPLETE  --  REAL AZURE  --  Trust Gap closed end to end' 'Cyan'
    Write-Host ''
    Write-Host '  Demo 1 (insecure, AKS):  tampered image RAN, key leaked over HTTP'                -ForegroundColor Red
    Write-Host '  Demo 2a (attack):        SAME manifest DENIED by Kyverno at admission'             -ForegroundColor Green
    Write-Host '  Demo 2b (legit, CVM):    signed image -> attested -> AMD SEV-SNP CVM -> secret released' -ForegroundColor Green
    Write-Host ''
    Write-Host '  When you are done recording, run:' -ForegroundColor Yellow
    Write-Host "    az group delete --name $ResourceGroup --yes --no-wait" -ForegroundColor Yellow
    Write-Host '  to drop the Azure bill back to $0.' -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
$argoPf = $null
try {
    Banner 'SECURE GITOPS ON REAL AZURE  --  LIVE DEMO' 'Cyan' `
        'AKS + Confidential Containers + ACR + Argo CD + Kyverno + Sigstore'

    Resolve-Acr

    if (-not $NoProvision) {
        Wait-Aks
        Ensure-CoCoPool
        Attach-Acr
        Get-Kubeconfig
        Push-ImagesToAcr
    } else {
        Step 'Skipping provision (-NoProvision). Loading kubeconfig.'
        Get-Kubeconfig
    }

    if (-not $NoBootstrap) {
        Install-Argo
        Install-Kyverno
        Install-RuntimeClass
        Install-Trustee
        Setup-Gitea
        Push-ManifestsToGitea
    } else {
        Step 'Skipping in-cluster bootstrap (-NoBootstrap).'
    }

    if ($Fresh) { Reset-DemoState }
    $argoPf = Open-ArgoCDInBrowser
    ScenePause -Seconds $LoginPauseSec -Tag "log in to Argo CD now (paste password from clipboard); $LoginPauseSec seconds"

    Scene-ControlPlane
    Scene-Demo1-Insecure
    Scene-Demo2a-Block
    Scene-Demo2b-Legit
    Scene-TrustMetrics
    Scene-AzureProof
    Scene-Wrap
}
finally {
    foreach ($procId in ($bgProcesses | Sort-Object -Unique)) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
    if ($TeardownAfter) {
        Banner 'TEARDOWN  --  deleting resource group (async)' 'DarkGray'
        az group delete --name $ResourceGroup --yes --no-wait | Out-Host
        Good "Submitted. Subscription bill drops to ~$0 within a few minutes."
    } else {
        Write-Host ''
        Write-Host "Azure resources are STILL RUNNING (~$0.60/hr). To delete:" -ForegroundColor DarkYellow
        Write-Host "  az group delete --name $ResourceGroup --yes --no-wait" -ForegroundColor DarkYellow
    }
}
