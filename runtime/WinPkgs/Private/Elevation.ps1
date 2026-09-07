function Test-WinPkgsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-WinPkgsExplorer {
    Write-Host 'Restarting Explorer so shell settings take effect'
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    # Windows normally relaunches the shell on its own; make sure.
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

function Invoke-WinPkgsElevatedApply {
    <#
    .SYNOPSIS
        Run `winpkgs.ps1 apply -Scope machine` once in an elevated child, with its
        output tee'd to a log the parent replays. One UAC prompt per apply.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Document)

    $entry = Join-Path $script:RuntimeRoot 'winpkgs.ps1'
    $logDir = Get-WinPkgsStateDir -Scope user
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir 'elevated.log'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

    $inner = "& '$entry' apply -Config '$($Document['path'])' -Scope machine -NoRestartExplorer *>&1 | Tee-Object -FilePath '$log'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $pwsh = (Get-Process -Id $PID).Path

    Write-Host '[machine] elevating for machine-scope changes (UAC prompt)...'
    try {
        $proc = Start-Process -FilePath $pwsh -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    } catch {
        throw "Elevation was refused or failed: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log | ForEach-Object { Write-Host "  $_" }
    }
    if ($proc.ExitCode -ne 0) {
        throw "Elevated apply failed with exit code $($proc.ExitCode); see $log"
    }
}
