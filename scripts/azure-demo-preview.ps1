#requires -Version 5.1
<#
.SYNOPSIS
  Read-only pre-flight overview for the Azure CoCo demo. Run this BEFORE
  azure-demo-full.ps1 (or before pressing record) to show the audience the
  lay of the land: Azure infra, CoCo node pool, control-plane pods, Kyverno
  policies, Trustee, Gitea, RuntimeClass, and a written preview of the two
  attacks the demo will perform.

  Does NOT modify anything in the cluster. Safe to re-run any number of times.

.EXAMPLE
  .\azure-demo-preview.ps1
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-secure-gitops-poc-ne',
    [string]$AksName       = 'aks-secure-gitops',
    [string]$AcrName       = ''
)

$ErrorActionPreference = 'Continue'

function Banner($title, $color = 'Cyan') {
    Write-Host ''
    Write-Host '========================================================================' -ForegroundColor $color
    Write-Host "  $title" -ForegroundColor $color
    Write-Host '========================================================================' -ForegroundColor $color
}
function Step($msg) { Write-Host ">> $msg" -ForegroundColor Yellow }
function Good($msg) { Write-Host "++ $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "!! $msg" -ForegroundColor Red }
function Note($msg) { Write-Host "   $msg" -ForegroundColor DarkGray }

# -----------------------------------------------------------------------------
Banner 'PRE-FLIGHT  --  SECURE GITOPS ON REAL AZURE CONFIDENTIAL CONTAINERS' 'Magenta'
Write-Host @'
This screen shows the COMPLETE environment that the demo will run against.
Nothing here is provisioned or modified -- it is a read-only snapshot.

Architecture:
  Argo CD  --(pull)-->  in-cluster Gitea  (GitOps source-of-truth)
       |
       v  applies K8s manifests through admission
  Kyverno (3 ClusterPolicies)  -- denies untrusted Deployments
       |
       v  admitted pods land here:
  AKS system pool (Ubuntu, runc)  -- bank-insecure (the trust gap)
  AKS cocopool   (AzureLinux, KataCcIsolation on AMD SEV-SNP CVMs)
                                  -- bank-secure (attested + key from Trustee)
'@ -ForegroundColor White

# -----------------------------------------------------------------------------
Banner 'AZURE INFRA' 'Cyan'

Step 'Subscription you are logged into:'
az account show --query "{name:name, id:id, user:user.name}" -o table

Write-Host ''
Step "Resource group + AKS cluster ($ResourceGroup / $AksName):"
az aks show -g $ResourceGroup -n $AksName `
    --query "{name:name, k8s:kubernetesVersion, region:location, fqdn:fqdn, powerState:powerState.code}" `
    -o table

Write-Host ''
Step 'Node pools (look for cocopool = AMD SEV-SNP Confidential VMs):'
az aks nodepool list -g $ResourceGroup --cluster-name $AksName `
    --query "[].{name:name, vmSize:vmSize, count:count, osSku:osSku, workloadRuntime:workloadRuntime, mode:mode, provisioningState:provisioningState}" `
    -o table

Write-Host ''
Step 'Container registry (where the bank-api images live):'
if (-not $AcrName) {
    $AcrName = az acr list -g $ResourceGroup --query '[0].name' -o tsv 2>$null
}
if ($AcrName) {
    az acr show -n $AcrName --query "{name:name, loginServer:loginServer, sku:sku.name, anonymousPullEnabled:anonymousPullEnabled}" -o table
    Write-Host ''
    Step 'Images pushed to ACR (the demo will pull from here):'
    az acr repository list -n $AcrName -o tsv | ForEach-Object {
        $tags = az acr repository show-tags -n $AcrName --repository $_ -o tsv
        foreach ($t in $tags) { Write-Host "  - $AcrName.azurecr.io/${_}:${t}" -ForegroundColor DarkGray }
    }
} else {
    Warn 'No ACR found in the resource group.'
}

# -----------------------------------------------------------------------------
Banner 'KUBERNETES NODES' 'Cyan'

Step 'All nodes with the kata-cc-isolation label highlighted:'
kubectl get nodes -L agentpool,kubernetes.azure.com/kata-cc-isolation -o wide
Write-Host ''
Step 'CoCo node detail (the per-pod CVM target):'
$cocoNode = kubectl get nodes -l 'kubernetes.azure.com/kata-cc-isolation=true' -o jsonpath='{.items[0].metadata.name}' 2>$null
if ($cocoNode) {
    Good "CoCo node: $cocoNode"
    kubectl get node $cocoNode -o jsonpath='{range .metadata.labels}{.kubernetes\.io/os-sku}{"\n"}{end}' 2>$null | Out-Null
    kubectl get node $cocoNode -o 'custom-columns=NAME:.metadata.name,VMSIZE:.metadata.labels.node\.kubernetes\.io/instance-type,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion'
} else {
    Warn 'No node with label kubernetes.azure.com/kata-cc-isolation=true. The CoCo pool may not be ready yet.'
}

# -----------------------------------------------------------------------------
Banner 'CONTROL-PLANE PODS (the security stack)' 'Cyan'

foreach ($ns in @('argocd', 'kyverno', 'attestation', 'gitea')) {
    Step "Namespace: $ns"
    $count = (kubectl get pods -n $ns --no-headers 2>$null | Measure-Object).Count
    if ($count -eq 0) {
        Warn "  (no pods -- $ns may not be bootstrapped yet; run azure-demo-full.ps1 once)"
    } else {
        kubectl get pods -n $ns -o 'custom-columns=POD:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,NODE:.spec.nodeName'
    }
    Write-Host ''
}

# -----------------------------------------------------------------------------
Banner 'RUNTIMECLASSES (which runtime each pod gets)' 'Cyan'
kubectl get runtimeclass -o 'custom-columns=NAME:.metadata.name,HANDLER:.handler,NODE_SELECTOR:.scheduling.nodeSelector'
Note '  - runc                -> default Linux containers (shared host kernel)  [bank-insecure]'
Note '  - kata-cc             -> per-pod AMD SEV-SNP CVM with attestation       [bank-secure]'
Note '  - kata-cc-isolation   -> AKS-auto-created alias for the same handler'

# -----------------------------------------------------------------------------
Banner 'KYVERNO CLUSTERPOLICIES (admission-time guards)' 'Cyan'
kubectl get clusterpolicy
Write-Host ''
Note 'disallow-plain-secret-mounts   - bank-secure pods cannot mount plain k8s Secrets'
Note 'require-runtime-class-kata-cc  - bank-secure pods MUST set runtimeClassName: kata-cc'
Note 'verify-image-cosign            - bank-* images must be Sigstore-signed (deleted at runtime'
Note '                                 for the Azure demo because ACR images are unsigned here)'

# -----------------------------------------------------------------------------
Banner 'TRUSTEE KBS (key broker that releases secrets after attestation)' 'Cyan'
kubectl get deploy,svc -n attestation 2>$null
Write-Host ''
Note 'Flow: bank-secure init container --(JWT + measurement)--> Trustee KBS'
Note '      Trustee verifies measurement -> releases DB key into /run/trustee/db-key'
Note '      App container reads the key from tmpfs; key NEVER hits etcd or the host.'

# -----------------------------------------------------------------------------
Banner 'GITEA (in-cluster GitOps source-of-truth)' 'Cyan'
kubectl get deploy,svc -n gitea 2>$null
Write-Host ''
Note "Repo URL (cluster-internal): http://gitea-http.gitea.svc.cluster.local:3000/demo/secure-gitops-poc.git"
Note 'Argo CD pulls from here. Image references are rewritten to your ACR on push.'

# -----------------------------------------------------------------------------
Banner 'ARGO CD APPLICATIONS' 'Cyan'
$apps = kubectl get applications -n argocd --no-headers 2>$null
if ($apps) {
    kubectl get applications -n argocd -o 'custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
} else {
    Note '(none yet -- Scene 1 / Scene 3 of the demo will create them)'
}

# -----------------------------------------------------------------------------
Banner 'THE TWO ATTACKS THIS DEMO WILL PERFORM' 'Red'
Write-Host @'

ATTACK #1 -- "Tampered image gets shipped via GitOps" (Scene 1, bank-insecure)
  * Argo CD pulls demo1-insecure/k8s from Gitea.
  * The Deployment references bank-api:tampered  (a backdoor build that exfiltrates
    the DB key in every HTTP response).
  * bank-insecure namespace has NO Kyverno policies attached.
  * Result we expect:
      - Pod RUNS on the regular Ubuntu node (runc, shared kernel).
      - The plain k8s Secret bank-db-key sits in etcd, base64 only.
      - curl /balance/alice returns:
           "leaked_key_prefix": "s3cr3tDB"     <-- the trust gap, on real AKS.
      - Argo CD UI tile shows GREEN: Synced + Healthy. Nothing looks wrong.

ATTACK #2 -- "Same attacker manifest arrives in bank-secure" (Scene 2)
  * kubectl apply of a Deployment without runtimeClassName, with a plain Secret
    volume, image bank-api:tampered.
  * bank-secure namespace HAS all 3 Kyverno policies bound.
  * Result we expect:
      Error from server: admission webhook "mutate.kyverno.svc-fail" denied:
        - disallow-plain-secret-mounts:   plain Secret volume rejected
        - require-runtime-class-kata-cc:  missing runtimeClassName rejected
      The attacker NEVER reaches the scheduler.

LEGITIMATE PATH -- "How the secure app actually ships" (Scene 3, bank-secure)
  * Argo CD pulls demo2-secure/k8s-kind from Gitea.
  * Deployment has runtimeClassName: kata-cc, init container = attestation-agent,
    no plain Secret volumes.
  * Pod is admitted, lands on the cocopool node, kata-cc spawns a per-pod
    AMD SEV-SNP CVM. Init container performs the Trustee handshake INSIDE the
    CVM, gets the DB key released into tmpfs, app container starts.
  * Result we expect:
      "image_variant": "clean"
      "decrypted_with": "key-fingerprint:TRUS***"
      NO leaked_key_prefix.
      Pod runs in encrypted RAM -- host kernel / cluster-admin cannot read the key.

'@ -ForegroundColor White

# -----------------------------------------------------------------------------
Banner 'READY TO RECORD' 'Green'
Write-Host @'

When you are ready, start the demo with:

    .\azure-demo-full.ps1 -NoProvision

(Defaults: ScenePauseSec=6, LoginPauseSec=20 -- gives you time to narrate
 and pan to the Argo CD browser tab between scenes.)

When the recording is done, drop Azure cost to $0 with:

    az group delete --name rg-secure-gitops-poc-ne --yes --no-wait

'@ -ForegroundColor White
