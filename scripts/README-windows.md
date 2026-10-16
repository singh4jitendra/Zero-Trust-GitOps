<#
.SYNOPSIS
  PowerShell wrappers for the secure-gitops POC demo scripts.

.DESCRIPTION
  The .sh scripts under poc/scripts/ are the canonical implementation.
  On Windows without git-bash/WSL, run the .ps1 wrappers here instead —
  they do exactly the same thing using native PowerShell.

  Usage:
    cd poc\scripts
    .\00-prereq-check.ps1
    .\01-bootstrap-local.ps1
    .\10-demo1-insecure.ps1
    .\20-demo2-secure-blocked.ps1
    .\21-demo2-secure-allowed.ps1
    .\99-reset.ps1
#>
