#requires -Version 5.1
<#
.SYNOPSIS  Verify toolchain for the secure-gitops POC demo (Windows).
#>
$ErrorActionPreference = 'Stop'

function Test-Tool {
    param([string]$Name, [string]$Cmd, [string[]]$VersionArgs = @('--version'))
    $found = Get-Command $Cmd -ErrorAction SilentlyContinue
    if ($found) {
        $ver = (& $Cmd @VersionArgs 2>&1 | Select-Object -First 1) -replace '^\s+|\s+$',''
        Write-Host ("OK  {0,-8} -> {1}" -f $Name, $ver) -ForegroundColor Green
        return $true
    }
    Write-Host ("MISS {0,-8} install before running the demo" -f $Name) -ForegroundColor Red
    return $false
}

Write-Host "== Prerequisite check ==" -ForegroundColor Cyan
$ok = $true
$ok = (Test-Tool 'docker'  'docker'  @('--version'))                     -and $ok
$ok = (Test-Tool 'kind'    'kind'    @('version'))                       -and $ok
$ok = (Test-Tool 'kubectl' 'kubectl' @('version','--client'))            -and $ok
$ok = (Test-Tool 'helm'    'helm'    @('version','--short'))             -and $ok
$ok = (Test-Tool 'cosign'  'cosign'  @('version'))                       -and $ok
$ok = (Test-Tool 'jq'      'jq'      @('--version'))                     -and $ok
$ok = (Test-Tool 'curl'    'curl'    @('--version'))                     -and $ok

if (-not $ok) { Write-Host "Install missing tools then re-run." -ForegroundColor Yellow; exit 1 }
Write-Host "All prerequisites present." -ForegroundColor Green
