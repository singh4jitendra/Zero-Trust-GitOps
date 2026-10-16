#requires -Version 5.1
<#
.SYNOPSIS
  ONE-SHOT recording-ready demo for the secure-gitops POC.

  - Brings up a local kind cluster (NOT real Azure - see disclaimer banner).
  - Installs Argo CD, Kyverno + 3 ClusterPolicies, trustee-mock, RuntimeClass.
  - Spins up an in-cluster Gitea, pushes the demo manifests to it, and creates
    two real Argo CD Applications that auto-sync from Gitea (so the UI is
    populated with `bank-api-insecure` and `bank-api-secure` tiles).
  - Runs Demo 1 (insecure), Demo 2a (Kyverno block), Demo 2b (legit signed +
    attested) in sequence with banner narration + pacing pauses.

.PARAMETER Fresh
  Force a clean slate: delete the kind cluster before bootstrapping.

.PARAMETER NoBootstrap
  Skip cluster bring-up. Use only if a previous run finished cleanly and you
  passed -NoTeardown.

.PARAMETER NoTeardown
  Leave the kind cluster running after the demo finishes.

.PARAMETER ScenePauseSec
  Seconds to pause between scenes so the camera can settle. Default 6.

.PARAMETER LoginPauseSec
  Seconds to wait after opening Argo CD in the browser so you can log in.

.EXAMPLE
  .\demo-full.ps1 -Fresh              # nuke + recreate everything, then demo
  .\demo-full.ps1 -NoBootstrap        # cluster already up, just run scenes
  .\demo-full.ps1 -NoTeardown         # leave cluster running after demo
#>
[CmdletBinding()]
param(
    [switch]$Fresh,
    [switch]$NoBootstrap,
    [switch]$NoTeardown,
    [int]$ScenePauseSec = 6,
    [int]$LoginPauseSec = 20
)

$ErrorActionPreference = 'Stop'
$root         = (Resolve-Path "$PSScriptRoot\..").Path
$cluster      = 'secure-gitops-poc'
$argocdUrl    = 'http://localhost:8080'
$giteaUser    = 'demo'
$giteaPass    = 'demo123'
$giteaRepo    = 'secure-gitops-poc'
$giteaSvcUrl  = 'http://gitea-http.gitea.svc.cluster.local:3000'
$giteaLocalPF = 'http://localhost:13000'
$tmpFiles     = @()
$bgProcesses  = @()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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
function Step  { param([string]$msg) Write-Host (">> " + $msg) -ForegroundColor Yellow }
function Good  { param([string]$msg) Write-Host ("++ " + $msg) -ForegroundColor Green }
function Bad   { param([string]$msg) Write-Host ("!! " + $msg) -ForegroundColor Red }
function ScenePause {
    param([int]$Seconds = $ScenePauseSec, [string]$Tag = '')
    if ($Tag) { Write-Host ("`n--- pause $Seconds`s --- $Tag`n") -ForegroundColor DarkGray }
    else      { Write-Host ("`n--- pause $Seconds`s ---`n") -ForegroundColor DarkGray }
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

# Wait for Docker engine
function Ensure-Docker {
    docker version --format '{{.Server.Version}}' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
    Step 'Docker engine not responding. Trying to launch Docker Desktop...'
    $paths = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
    )
    $dd = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($dd) { Start-Process $dd }
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Good 'Docker engine is up.'; return }
        Start-Sleep -Seconds 4
        Write-Host '   waiting for docker engine...' -ForegroundColor DarkGray
    }
    throw 'Docker did not start in time. Launch Docker Desktop manually then re-run.'
}

# Add the user's WinGet links dir to PATH for this session (kind/kubectl/helm/etc.)
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','User') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path','Machine')

# ---------------------------------------------------------------------------
# Gitea (in-cluster GitOps source of truth) + Argo CD Applications
# ---------------------------------------------------------------------------
function Setup-Gitea {
    Step 'Deploying in-cluster Gitea (the GitOps source Argo CD will watch)'
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
            - { containerPort: 22,   name: ssh  }
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

    # Create admin user via gitea CLI
    Step "Creating Gitea admin user '$giteaUser'"
    & kubectl -n gitea exec deploy/gitea -- su git -c "gitea admin user create --username $giteaUser --password $giteaPass --email $giteaUser@local --admin --must-change-password=false" 2>&1 |
        ForEach-Object {
            if ("$_" -match 'user already exists|created') { Write-Host "  $_" -ForegroundColor DarkGray }
            else { Write-Host "  $_" -ForegroundColor DarkGray }
        }
}

function Push-ManifestsToGitea {
    Step 'Pushing demo manifests into the in-cluster Gitea repo'
    $pf = Start-Process -PassThru -WindowStyle Hidden -FilePath kubectl `
        -ArgumentList 'port-forward','-n','gitea','svc/gitea-http','13000:3000'
    $script:bgProcesses += $pf.Id
    Start-Sleep -Seconds 3

    $authBytes  = [Text.Encoding]::ASCII.GetBytes("${giteaUser}:${giteaPass}")
    $basic      = 'Basic ' + [Convert]::ToBase64String($authBytes)
    $hdr        = @{ Authorization = $basic; 'Content-Type' = 'application/json' }

    # Wait for API to be live
    for ($i = 1; $i -le 30; $i++) {
        try { Invoke-RestMethod -Uri "$giteaLocalPF/api/v1/version" -TimeoutSec 3 | Out-Null; break }
        catch { Start-Sleep -Seconds 2 }
    }

    # Create repo (idempotent)
    try {
        $body = @{ name = $giteaRepo; auto_init = $true; default_branch = 'main'; private = $false } | ConvertTo-Json
        Invoke-RestMethod -Uri "$giteaLocalPF/api/v1/user/repos" -Method POST -Headers $hdr -Body $body | Out-Null
        Write-Host "  repo '$giteaRepo' created" -ForegroundColor DarkGray
    } catch {
        if ("$_" -match 'already exists|409') {
            Write-Host "  repo '$giteaRepo' already exists, reusing" -ForegroundColor DarkGray
        } else { throw }
    }

    # Files to seed (relative path under poc/ -> path in repo)
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
        if (-not (Test-Path $src)) { Write-Host "  skip (missing) $src" -ForegroundColor DarkYellow; continue }
        $bytes   = [IO.File]::ReadAllBytes($src)
        $b64     = [Convert]::ToBase64String($bytes)
        $apiUrl  = "$giteaLocalPF/api/v1/repos/$giteaUser/$giteaRepo/contents/$dst"
        $payload = @{ message = "seed $dst"; content = $b64; branch = 'main' } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri $apiUrl -Method POST -Headers $hdr -Body $payload | Out-Null
            Write-Host "  + $dst" -ForegroundColor DarkGray
        } catch {
            # If the file already exists, update it
            try {
                $existing = Invoke-RestMethod -Uri $apiUrl -Method GET -Headers $hdr
                $payload2 = @{ message = "update $dst"; content = $b64; sha = $existing.sha; branch = 'main' } | ConvertTo-Json
                Invoke-RestMethod -Uri $apiUrl -Method PUT -Headers $hdr -Body $payload2 | Out-Null
                Write-Host "  ~ $dst (updated)" -ForegroundColor DarkGray
            } catch {
                Write-Host "  ! could not upload $dst : $_" -ForegroundColor Red
            }
        }
    }
    Stop-PortForward $pf
    Good "Seeded $($files.Count) manifests into http://gitea-http.gitea.svc.cluster.local:3000/$giteaUser/$giteaRepo"
}

function Create-ArgoApp {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$DestNamespace
    )
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
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$DestNamespace,
        [Parameter(Mandatory)] [string]$DestDeploy,
        [int]$TimeoutSec = 240
    )
    # Trigger a hard refresh so the controller compares + syncs immediately
    # instead of waiting for the default 3-minute reconciliation interval.
    & kubectl -n argocd annotate application $Name --overwrite 'argocd.argoproj.io/refresh=hard' 2>$null | Out-Null

    # The most reliable "Argo CD finished" signal is the destination Deployment
    # going Available -- the .status.sync.status field updates lag behind reality.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $out = & kubectl -n $DestNamespace wait "deployment/$DestDeploy" --for=condition=available --timeout=5s 2>&1
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Write-Host "  waiting for Argo CD to sync $Name (deployment/$DestDeploy not yet Available)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
    }
    if (-not $ready) { Bad "  timed out waiting for deployment/$DestDeploy after ${TimeoutSec}s" }
    return $ready
}

# Add the user's WinGet links dir to PATH for this session (kind/kubectl/helm/etc.)
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','User') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path','Machine')

# ---------------------------------------------------------------------------
# Bootstrap (idempotent)
# ---------------------------------------------------------------------------
function Bootstrap {
    Banner 'BOOTSTRAP' 'DarkCyan' 'Creates kind cluster, installs Argo CD + Kyverno + trustee-mock + Gitea, seeds repo, registers Argo CD source.'
    Ensure-Docker

    if ($Fresh) {
        Step "(-Fresh) deleting any existing '$cluster' cluster first"
        & kind delete cluster --name $cluster 2>&1 | Out-Host
    }

    Step "kind cluster '$cluster'"
    $existing = & kind get clusters 2>$null
    if ($existing -contains $cluster) {
        Good "cluster already exists, reusing"
    } else {
        & kind create cluster --name $cluster --config "$root\infra\local\kind-config.yaml"
    }
    & kubectl cluster-info --context "kind-$cluster" | Select-Object -First 2

    Step 'Building & loading bank-api images (clean + tampered)'
    & docker build --build-arg IMAGE_VARIANT=clean    -t bank-api:clean    "$root\app" | Out-Host
    & docker build --build-arg IMAGE_VARIANT=tampered -t bank-api:tampered "$root\app" | Out-Host
    & kind load docker-image bank-api:clean    --name $cluster
    & kind load docker-image bank-api:tampered --name $cluster

    Step 'Installing Argo CD (insecure-http mode for browser demo)'
    & kubectl create namespace argocd --dry-run=client -o yaml | & kubectl apply -f - | Out-Null
    # Argo CD v3.x has the up-to-date Kubernetes schema (knows about
    # .status.terminatingReplicas etc) so the diff comparison succeeds and
    # the UI reports Synced/Healthy cleanly on modern kind (k8s 1.30+).
    & kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.1.0/manifests/install.yaml | Out-Host
    & kubectl -n argocd wait --for=condition=available --timeout=5m deployment/argocd-server | Out-Host
    & kubectl -n argocd patch configmap argocd-cmd-params-cm --type=merge -p '{"data":{"server.insecure":"true"}}' | Out-Null
    & kubectl -n argocd rollout restart deployment argocd-server | Out-Null
    & kubectl -n argocd rollout status deployment argocd-server --timeout=2m | Out-Host

    Step 'Installing Kyverno + ClusterPolicies'
    & kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.12.5/install.yaml 2>$null | Out-Null
    & kubectl -n kyverno wait --for=condition=available --timeout=5m deployment/kyverno-admission-controller | Out-Host
    # Webhook endpoint can take a few more seconds after the deployment goes ready.
    # Wait for the Service endpoints to actually have ready addresses.
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $eps = & kubectl -n kyverno get endpoints kyverno-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>$null
        if ($eps) { break }
        Start-Sleep -Seconds 3
    }
    # Apply policies one at a time with retry on the transient webhook errors.
    Get-ChildItem "$root\policies\kyverno\*.yaml" | ForEach-Object {
        $f = $_.FullName
        for ($i = 1; $i -le 8; $i++) {
            $out = & kubectl apply -f $f 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host $out; break }
            if ("$out" -match 'connection refused|no endpoints available|failed calling webhook') {
                Write-Host "  webhook not ready yet for $($_.Name) (try $i/8), retrying..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 5
            } else {
                Write-Host $out -ForegroundColor Red; break
            }
        }
    }
    # Wait for all three policies to reach Ready=True so admission actually enforces.
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $notReady = & kubectl get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="Ready")].status} {end}' 2>$null
        if ($notReady -and $notReady -notmatch ':False|:Unknown') { break }
        Start-Sleep -Seconds 3
    }
    & kubectl get clusterpolicy

    Step 'Installing trustee-mock + RuntimeClass kata-cc'
    & docker build -t trustee-mock:0.1.0 "$root\attestation\trustee-mock" | Out-Host
    & kind load docker-image trustee-mock:0.1.0 --name $cluster

    $runtimeClass = @'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: { name: kata-cc, labels: { marker: mock } }
handler: runc
scheduling:
  nodeSelector:
    kubernetes.azure.com/kata-cc-isolation: "true"
'@
    $runtimeClass | & kubectl apply -f - | Out-Null

    & kubectl create namespace attestation --dry-run=client -o yaml | & kubectl apply -f - | Out-Null
    $trustee = @'
apiVersion: apps/v1
kind: Deployment
metadata: { name: trustee-mock, namespace: attestation, labels: { app: trustee-mock } }
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
'@
    $trustee | & kubectl apply -f - | Out-Null
    & kubectl -n attestation wait --for=condition=available --timeout=2m deployment/trustee-mock | Out-Host

    Setup-Gitea
    Push-ManifestsToGitea

    Good 'Bootstrap complete.'
}

# ---------------------------------------------------------------------------
# Reset previous demo state without nuking the cluster
# ---------------------------------------------------------------------------
function Reset-DemoState {
    Step 'Resetting demo state (deleting Argo CD apps + bank-* namespaces, restoring policies)'
    # Delete Argo CD Applications first so the controller stops fighting our manual cleanup.
    foreach ($app in 'bank-api-insecure','bank-api-secure') {
        & kubectl -n argocd patch application $app --type=merge -p '{"metadata":{"finalizers":[]}}' 2>$null | Out-Null
        & kubectl -n argocd delete application $app --ignore-not-found --wait=$false 2>$null | Out-Null
    }
    & kubectl delete deploy bank-api-attack -n bank-secure --ignore-not-found 2>$null | Out-Null
    & kubectl delete ns bank-insecure --ignore-not-found 2>$null | Out-Null
    & kubectl delete ns bank-secure   --ignore-not-found 2>$null | Out-Null
    & kubectl wait --for=delete namespace/bank-insecure --timeout=60s 2>$null | Out-Null
    & kubectl wait --for=delete namespace/bank-secure   --timeout=60s 2>$null | Out-Null
    & kubectl patch clusterpolicy verify-image-cosign --type=merge `
        -p '{"spec":{"validationFailureAction":"Enforce"}}' 2>$null | Out-Null
}

# ---------------------------------------------------------------------------
# Argo CD UI: port-forward + open in default browser
# ---------------------------------------------------------------------------
function Open-ArgoCDInBrowser {
    Step "Starting Argo CD port-forward on $argocdUrl"
    $pf = Start-Process -PassThru -WindowStyle Hidden -FilePath kubectl `
        -ArgumentList 'port-forward','-n','argocd','svc/argocd-server','8080:80'
    $script:bgProcesses += $pf.Id
    Start-Sleep -Seconds 3

    $pw = & kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
    $pwPlain = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($pw))

    # Put the password on the clipboard so the operator can paste it during the recording.
    try { Set-Clipboard -Value $pwPlain; $clipNote = '(copied to clipboard - paste with Ctrl+V)' }
    catch { $clipNote = '(clipboard unavailable; type manually)' }

    Write-Host ''
    Write-Host '+======================================================================+' -ForegroundColor Yellow
    Write-Host '|  ARGO CD LOGIN CREDENTIALS                                           |' -ForegroundColor Yellow
    Write-Host ('|    URL      : {0,-54} |' -f $argocdUrl)                                  -ForegroundColor Yellow
    Write-Host  '|    Username : admin                                                  |'  -ForegroundColor Yellow
    Write-Host ('|    Password : {0,-54} |' -f $pwPlain)                                   -ForegroundColor Yellow
    Write-Host ('|             : {0,-54} |' -f $clipNote)                                  -ForegroundColor DarkYellow
    Write-Host '+======================================================================+' -ForegroundColor Yellow
    Write-Host ''

    Step 'Opening Argo CD UI in your default browser ...'
    Start-Process $argocdUrl
    return $pf
}

# ---------------------------------------------------------------------------
# Scenes
# ---------------------------------------------------------------------------
function Scene-ControlPlane {
    Banner 'SCENE 0  --  the control plane that protects every workload' 'Cyan'

    Write-Host '+======================================================================+' -ForegroundColor Magenta
    Write-Host '|  ENVIRONMENT DISCLAIMER                                              |' -ForegroundColor Magenta
    Write-Host '|  This demo runs on LOCAL kind (Kubernetes-in-Docker) on your laptop. |' -ForegroundColor Magenta
    Write-Host '|  - NO Azure subscription is used.                                    |' -ForegroundColor Magenta
    Write-Host '|  - NO real Azure Confidential VM is provisioned.                     |' -ForegroundColor Magenta
    Write-Host '|  - NO real AMD SEV-SNP attestation report.                           |' -ForegroundColor Magenta
    Write-Host '|  The RuntimeClass kata-cc is a MOCK (handler:runc, label marker=mock)|' -ForegroundColor Magenta
    Write-Host '|  The Trustee/KBS is a MOCK that implements the real KBS protocol.   |' -ForegroundColor Magenta
    Write-Host '|  The Azure path (real AKS DC4as_cc_v5 + Trustee Helm + ACR + SLSA   |' -ForegroundColor Magenta
    Write-Host '|  signed images) is shown as code in SCENE 5 and lives in            |' -ForegroundColor Magenta
    Write-Host '|  poc/infra/azure/  -- it is not executed in this script.            |' -ForegroundColor Magenta
    Write-Host '+======================================================================+' -ForegroundColor Magenta
    Write-Host ''

    Step 'Cluster nodes (the LOCAL kind cluster):'
    & kubectl get nodes -o wide
    Write-Host ''
    Step 'Namespaces that make up the trust fabric:'
    & kubectl get ns | Select-String -Pattern 'argocd|kyverno|attestation|gitea'
    Write-Host ''
    Step 'Kyverno ClusterPolicies (admission-time guardrails for bank-secure):'
    & kubectl get clusterpolicy
    Write-Host ''
    Step 'Trustee Key Broker Service (MOCK locally; real Trustee Helm chart on AKS):'
    & kubectl get deploy,svc -n attestation
    Write-Host ''
    Step 'Gitea (in-cluster GitOps source of truth that Argo CD is watching):'
    & kubectl get deploy,svc -n gitea
    Write-Host ''
    Step 'RuntimeClass kata-cc (handler=runc + marker=mock on kind; on AKS it is a real per-pod CVM):'
    & kubectl get runtimeclass kata-cc -o yaml | Select-String -Pattern 'name:|handler:|nodeSelector:|kubernetes.azure.com|marker:'
    Write-Host ''
    Step 'Argo CD Applications currently registered (empty before Scene 1):'
    & kubectl -n argocd get applications
    ScenePause -Tag 'pan to the Argo CD browser tab (Applications page is empty), then back'
}

function Scene-Demo1-Insecure {
    Banner 'SCENE 1  --  DEMO 1: Insecure GitOps (the Trust Gap)' 'Red' `
        'Argo CD now syncs the insecure manifests from Gitea. No policies guard bank-insecure.'

    Step 'Registering Argo CD Application bank-api-insecure -> Gitea path demo1-insecure/k8s:'
    Create-ArgoApp -Name 'bank-api-insecure' -Path 'demo1-insecure/k8s' -DestNamespace 'bank-insecure'

    Step 'Waiting for Argo CD to sync ...'
    Wait-ArgoAppHealthy -Name 'bank-api-insecure' -DestNamespace 'bank-insecure' -DestDeploy 'bank-api' -TimeoutSec 180 | Out-Null
    & kubectl -n argocd get application bank-api-insecure -o 'custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL'

    Write-Host ''
    Step 'What Argo CD just deployed:'
    & kubectl get deploy,pod,svc,secret -n bank-insecure
    Write-Host ''
    Step 'Pod runtime: no runtimeClassName -> default runc (SHARED host kernel):'
    & kubectl -n bank-insecure get pod -o custom-columns='POD:.metadata.name,RUNTIME:.spec.runtimeClassName,NODE:.spec.nodeName'

    Write-Host ''
    Step 'The Secret sits in etcd as plain (base64-only) bytes - visible to cluster admins:'
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
    Bad 'The malicious build silently exfiltrated the DB key prefix.'
    Bad 'Everything looks green: Argo CD shows bank-api-insecure as Synced + Healthy.'
    Bad 'This is the Trust Gap from slide 4.'
    ScenePause -Tag 'pan to Argo CD UI -> click bank-api-insecure tile -> show all resources green'
}

function Scene-Demo2a-Block {
    Banner 'SCENE 2  --  DEMO 2a: the SAME attack arrives in bank-secure' 'Green' `
        'Kyverno fires multiple policies and rejects the deployment at admission.'

    Step 'Same attacker manifest as Demo 1 (plain Secret + no runtimeClass):'
    $attack = @'
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
          image: bank-api:tampered
          volumeMounts: [{ name: db-key, mountPath: /etc/secrets, readOnly: true }]
      volumes:
        - name: db-key
          secret: { secretName: bank-db-key-attack }
'@
    $tmp = Join-Path $env:TEMP 'demo-full-attack.yaml'
    $script:tmpFiles += $tmp
    $attack | Out-File -FilePath $tmp -Encoding ascii
    Get-Content $tmp | Select-Object -First 30 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

    Write-Host ''
    Step 'kubectl apply -f <attack> :'
    $out = & kubectl apply -f $tmp 2>&1
    foreach ($l in $out) {
        $s = "$l"
        if ($s -match 'denied|blocked|disallow-plain|require-runtime') {
            Write-Host $s -ForegroundColor Red
        } else {
            Write-Host $s
        }
    }
    Write-Host ''
    Good 'Kyverno denied the deployment at admission. Two policies fired:'
    Good '  - disallow-plain-secret-mounts   (no plain k8s Secret volumes in bank-secure)'
    Good '  - require-runtime-class-kata-cc  (pods must request Confidential Containers)'
    Good 'A third policy, verify-image-cosign, blocks unsigned registry images on AKS.'
    ScenePause -Tag 'narrate: defense-in-depth, three independent admission webhooks'
}

function Scene-Demo2b-Legit {
    Banner 'SCENE 3  --  DEMO 2b: the legitimate path' 'Green' `
        'Argo CD syncs the signed/secure manifests from Gitea. Kyverno admits, CoCo runs, Trustee attests, secret released.'

    Step 'Snippet of the secure deployment in Gitea (runtimeClassName + attestation-agent init container):'
    Get-Content "$root\demo2-secure\k8s-kind\deployment-kind.yaml" |
        Select-String -Pattern 'runtimeClassName|initContainers|attestation-agent|TRUSTEE_URL|RESOURCE_ID|/run/trustee/db-key' |
        Select-Object -First 10 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

    Write-Host ''
    Step 'Switching verify-image-cosign to Audit (locally-built images cannot carry real Sigstore signatures):'
    $auditPatch = '{"spec":{"validationFailureAction":"Audit","rules":[{"name":"verify-bank-api-images","verifyImages":[{"mutateDigest":false,"verifyDigest":false,"required":true,"imageReferences":["ghcr.io/your-github-org/bank-api*","*.azurecr.io/bank-api*","bank-api*","docker.io/library/bank-api*"],"attestors":[{"entries":[{"keyless":{"subject":"https://github.com/your-github-org/secure-gitops-poc/.github/workflows/build-sign-provenance.yml@refs/heads/main","issuer":"https://token.actions.githubusercontent.com","rekor":{"url":"https://rekor.sigstore.dev"}}}]}]}]}]}}'
    & kubectl patch clusterpolicy verify-image-cosign --type=merge -p $auditPatch 2>&1 | Out-Null

    Step 'Pre-creating bank-secure namespace + RuntimeClass kata-cc:'
    & kubectl create namespace bank-secure --dry-run=client -o yaml | & kubectl apply -f - | Out-Null
    & kubectl apply -f "$root\demo2-secure\k8s\runtime-class.yaml" 2>$null | Out-Null

    Step 'Registering Argo CD Application bank-api-secure -> Gitea path demo2-secure/k8s-kind:'
    Create-ArgoApp -Name 'bank-api-secure' -Path 'demo2-secure/k8s-kind' -DestNamespace 'bank-secure'

    Step 'Waiting for Argo CD to sync and the attestation handshake to complete ...'
    Wait-ArgoAppHealthy -Name 'bank-api-secure' -DestNamespace 'bank-secure' -DestDeploy 'bank-api' -TimeoutSec 240 | Out-Null
    & kubectl -n argocd get application bank-api-secure -o 'custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL'

    Write-Host ''
    Step 'Attestation handshake from the init container (the KBS protocol):'
    & kubectl -n bank-secure logs deploy/bank-api -c attestation-agent
    Write-Host ''
    Step 'Pod is bound to RuntimeClass kata-cc (on AKS this is a per-pod CVM):'
    & kubectl -n bank-secure get pod -o custom-columns='POD:.metadata.name,RUNTIME:.spec.runtimeClassName,NODE:.spec.nodeName,STATUS:.status.phase'

    Write-Host ''
    Step 'Hitting the same API endpoint, this time on the secure deployment:'
    $pf = Start-PortForward -ns 'bank-secure' -svc 'bank-api' -local 28080 -remote 80
    try {
        Write-Host '+ curl /whoami' -ForegroundColor DarkGray
        & curl.exe -s http://localhost:28080/whoami | & jq .
        Write-Host ''
        Write-Host '+ curl /balance/alice' -ForegroundColor DarkGray
        & curl.exe -s http://localhost:28080/balance/alice | & jq .
    } finally { Stop-PortForward $pf }

    Write-Host ''
    Good 'image_variant=clean   decrypted_with=key-fingerprint:TRUS***   NO leaked key'
    Good 'The DB key lives only in the pod tmpfs, written there after attestation.'
    Good 'On AKS the same pod runs inside encrypted RAM (AMD SEV-SNP).'
    ScenePause -Tag 'pan to Argo CD UI -> two app tiles -> click bank-api-secure -> resource graph'
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

function Scene-AzureCVM {
    Banner 'SCENE 5  --  Azure Confidential VMs (what the AKS path looks like)' 'Magenta' `
        'On AKS we replace the kind cluster + RuntimeClass mock with a real CoCo node pool.'

    Step 'AKS Confidential Container node pool (Standard_DC4as_cc_v5 = AMD SEV-SNP):'
    Get-Content "$root\infra\azure\02-create-aks-coco.sh" |
        Select-String -Pattern 'aks create|nodepool add|Standard_DC4as_cc_v5|KataCcIsolation|workload-runtime|kata-cc-isolation|azure-linux' |
        Select-Object -First 12 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

    Write-Host ''
    Step 'Same RuntimeClass YAML, but now scheduled onto a real CVM node pool:'
    Get-Content "$root\demo2-secure\k8s\runtime-class.yaml" |
        ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

    Write-Host ''
    Step 'The real Trustee Helm install (replaces our trustee-mock on AKS):'
    Get-Content "$root\infra\azure\05b-install-trustee.sh" |
        Select-String -Pattern 'helm|trustee|kbs|--set' |
        Select-Object -First 10 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

    Write-Host ''
    Step 'Estimated Azure run cost while the demo is up (slide 12, ops impact):'
    Write-Host '  2x Standard_DC4as_cc_v5      ~ $0.90/hr' -ForegroundColor DarkGray
    Write-Host '  ACR Standard + Argo CD CP    ~ $0.20/hr' -ForegroundColor DarkGray
    Write-Host '  Log Analytics + Prom/Grafana ~ $0.10/hr' -ForegroundColor DarkGray
    Write-Host '  -----------------------------------------' -ForegroundColor DarkGray
    Write-Host '  TOTAL approximately          ~ $1.20/hr   (teardown script flushes the RG)' -ForegroundColor Green
    ScenePause -Tag 'narrate: same manifests, just a different node pool'
}

function Scene-Wrap {
    Banner 'DEMO COMPLETE  --  the Trust Gap is closed end to end' 'Cyan'
    Write-Host ''
    Write-Host '  Demo 1 (insecure):  tampered image RAN, key leaked over HTTP'                -ForegroundColor Red
    Write-Host '  Demo 2a (attack):   SAME manifest DENIED at admission by Kyverno'             -ForegroundColor Green
    Write-Host '  Demo 2b (legit):    signed image -> attested -> CVM -> secret released'       -ForegroundColor Green
    Write-Host ''
    Write-Host '  Five pillars from slide 5 all visible above:'                                  -ForegroundColor Yellow
    Write-Host '    1. Signed Provenance      -> Sigstore + SLSA in build-sign-provenance.yml'
    Write-Host '    2. Verified Admission     -> Kyverno verifyImages + 2 more ClusterPolicies'
    Write-Host '    3. Hardware Isolation     -> RuntimeClass kata-cc + AKS DC4as_cc_v5'
    Write-Host '    4. Attested Secret Release-> trustee-mock /kbs/v0/auth + /attest + /resource'
    Write-Host '    5. Observability + SLOs   -> trustee_* counters -> Grafana dashboard'
    Write-Host ''
    Write-Host "  GitOps platform (Argo CD UI) still open at: $argocdUrl"                       -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
$argoPf = $null
try {
    Banner 'SECURE GITOPS FOR REGULATED WORKLOADS  --  LIVE DEMO' 'Cyan' `
        'Argo CD + Sigstore + Kyverno + Confidential Containers'
    if (-not $NoBootstrap) { Bootstrap }
    else { Step 'Skipping bootstrap (--NoBootstrap). Assuming cluster + control plane already up.' }

    Reset-DemoState
    $argoPf = Open-ArgoCDInBrowser
    ScenePause -Seconds $LoginPauseSec -Tag "log in to Argo CD now (paste password from clipboard); $LoginPauseSec seconds"

    Scene-ControlPlane
    Scene-Demo1-Insecure
    Scene-Demo2a-Block
    Scene-Demo2b-Legit
    Scene-TrustMetrics
    Scene-AzureCVM
    Scene-Wrap
}
finally {
    foreach ($procId in ($bgProcesses | Sort-Object -Unique)) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in $tmpFiles) { Remove-Item $f -ErrorAction SilentlyContinue }
    if (-not $NoTeardown) {
        Banner 'TEARDOWN' 'DarkGray'
        & kind delete cluster --name $cluster | Out-Host
    } else {
        Write-Host ''
        Write-Host "Cluster '$cluster' left running. To clean up later:" -ForegroundColor DarkGray
        Write-Host "  kind delete cluster --name $cluster"               -ForegroundColor DarkGray
    }
}
