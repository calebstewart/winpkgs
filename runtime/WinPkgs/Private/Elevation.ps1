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

function Test-WinPkgsPackagedHost {
    # The MSIX (Store) build of pwsh lives under WindowsApps.
    return ($PSHOME -like (Join-Path $env:ProgramFiles 'WindowsApps\*'))
}

function Get-WinPkgsElevationHost {
    <#
    .SYNOPSIS
        The PowerShell executable to run the elevated phase with.

    .DESCRIPTION
        A UAC-elevated MSIX-packaged pwsh cannot open HKLM\SOFTWARE for write or
        delete registry keys -- even the raw .NET API answers "Requested registry
        access is not allowed" -- although it can set values in existing keys,
        which is how the failure hides. winget installs the MSIX by default from
        7.6 and only the MSIX from 7.7, so the machine-scope phase runs under an
        unpackaged host: this pwsh if it is not packaged, else an MSI/zip pwsh in
        Program Files, else Windows PowerShell 5.1, which always exists. The
        runtime stays compatible with 5.1 for exactly this reason.
    #>
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not (Test-WinPkgsPackagedHost)) {
        return (Get-Process -Id $PID).Path
    }
    $unpackaged = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $unpackaged) { return $unpackaged }
    return Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Format-WinPkgsCommandArguments {
    # Render arguments for a PowerShell command line: parameter names stay bare
    # (a quoted '-Config' is a string value, not a parameter), values are quoted.
    param([string[]]$Arguments)
    $tokens = foreach ($a in $Arguments) {
        if ($a -match '^-[A-Za-z][A-Za-z0-9]*$') { $a } else { "'" + ($a -replace "'", "''") + "'" }
    }
    return ($tokens -join ' ')
}

function New-WinPkgsElevatedScript {
    # The script the elevated child runs: the runtime with its output tee'd to a
    # log. A terminating error inside the runtime escapes the Tee-Object pipeline
    # and would only reach the hidden window's stderr; catch it and log it.
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string[]]$RuntimeArgs,
        [Parameter(Mandatory)][string]$Log
    )
    $arguments = Format-WinPkgsCommandArguments -Arguments $RuntimeArgs
    return @"
`$ErrorActionPreference = 'Stop'
try {
    & '$Entry' $arguments *>&1 | Tee-Object -FilePath '$Log'
} catch {
    "ERROR: `$(`$_.Exception.Message)" | Tee-Object -FilePath '$Log' -Append
    `$_.InvocationInfo.PositionMessage | Tee-Object -FilePath '$Log' -Append
    exit 1
}
"@
}

function Invoke-WinPkgsElevated {
    <#
    .SYNOPSIS
        Run winpkgs.ps1 once in an elevated child with the given arguments, with
        its output tee'd to a log the parent replays. One UAC prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$RuntimeArgs,
        [string]$Label = 'machine'
    )

    $entry = Join-Path $script:RuntimeRoot 'winpkgs.ps1'
    $logDir = Get-WinPkgsStateDir -Kind home
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir 'elevated.log'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

    $inner = New-WinPkgsElevatedScript -Entry $entry -RuntimeArgs $RuntimeArgs -Log $log
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $exe = Get-WinPkgsElevationHost

    Write-Host "[$Label] elevating for machine-scope changes (UAC prompt; host: $exe)..."
    try {
        $proc = Start-Process -FilePath $exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    } catch {
        throw "Elevation was refused or failed: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log | ForEach-Object { Write-Host "  $_" }
    }
    if ($proc.ExitCode -ne 0) {
        throw "Elevated $Label phase failed with exit code $($proc.ExitCode); see $log"
    }
}
