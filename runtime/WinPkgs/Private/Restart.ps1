<#
    Whether the machine has to restart before what was just applied takes
    effect, and how that reaches whoever asked for the apply.

    Some values are read once by something no restart of Explorer can reach: a
    driver loaded at boot, the computer's own name. A resource carrying
    `restartMachine` records that, and `winpkgs.ps1 apply` leaves with exit code
    3010 -- what Windows itself answers for the same thing, and what DISM says
    after enabling a feature, so a caller that already understands one
    understands this.

    The runtime never restarts anything. It is not its machine to reboot: an
    apply might be one step of several, or running while someone is working.
    Saying so and letting the caller decide is the whole contract.
#>

$script:RestartRequired = $false
$script:RestartReasons = New-Object Collections.Generic.List[string]

# The code Windows uses for "done, but restart before you believe it".
$script:ExitRestartRequired = 3010

function Set-WinPkgsRestartRequired {
    param([Parameter(Mandatory)][string]$Because)
    $script:RestartRequired = $true
    if (-not $script:RestartReasons.Contains($Because)) { $script:RestartReasons.Add($Because) }
}

function Test-WinPkgsRestartRequired {
    <#
    .SYNOPSIS
        Did anything applied in this process need the machine to restart?
    #>
    return $script:RestartRequired
}

function Get-WinPkgsRestartReasons {
    return , @($script:RestartReasons)
}

function Write-WinPkgsRestartNotice {
    param([Parameter(Mandatory)][string]$Kind)
    if (-not $script:RestartRequired) { return }
    Write-Host ''
    Write-Host "[$Kind] a restart is needed before these take effect:" -ForegroundColor Yellow
    foreach ($r in $script:RestartReasons) { Write-Host "  $r" -ForegroundColor Yellow }
}
