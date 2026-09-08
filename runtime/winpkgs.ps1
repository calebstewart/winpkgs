#Requires -Version 5.1
<#
.SYNOPSIS
    winpkgs runtime entry point: converge a Windows machine to a desired-state document.

    Runs under pwsh 7 or Windows PowerShell 5.1. The elevated (machine-scope)
    phase deliberately uses an unpackaged host, which on a machine with only the
    MSIX pwsh means 5.1 -- see Get-WinPkgsElevationHost.

.DESCRIPTION
    plan         Show what apply would change. Reads every scope; needs no elevation.
    apply        Converge. User scope runs here; machine scope elevates once if needed.
    rollback     Undo a generation: rollback N. Generations are numbered in one
                 sequence across scopes; -Scope only disambiguates old ones.
    generations  List recorded generations for both scopes.

.EXAMPLE
    .\winpkgs.ps1 plan -Config \\wsl.localhost\NixOS\nix\store\...-winpkgs-desktop\config.json
.EXAMPLE
    .\winpkgs.ps1 apply -Config C:\src\closure\config.json
.EXAMPLE
    .\winpkgs.ps1 rollback 3
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'apply', 'rollback', 'generations', 'status')]
    [string]$Command = 'plan',

    [Alias('c')]
    [string]$Config,

    [ValidateSet('auto', 'user', 'machine')]
    [string]$Scope = 'auto',

    # rollback: the generation to undo. Positional, so `rollback 12` works.
    [Parameter(Position = 1)]
    [int]$Generation = 0,

    # Apply user scope only; report machine-scope drift instead of prompting for UAC.
    [switch]$NoElevate,

    [switch]$NoRestartExplorer,

    # plan: include resources already in their desired state.
    [switch]$ShowUnchanged
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinPkgs') -Force

function Get-Document {
    if (-not $Config) { throw "-Config <path to config.json> is required for '$Command'" }
    Read-WinPkgsDocument -Path $Config
}

switch ($Command) {
    'plan' {
        $doc = Get-Document
        $scopes = if ($Scope -eq 'auto') { @('user', 'machine') } else { @($Scope) }
        Get-WinPkgsPlan -Document $doc -Scope $scopes | Format-WinPkgsPlan -ShowUnchanged:$ShowUnchanged
    }
    'apply' {
        $doc = Get-Document
        Invoke-WinPkgsApply -Document $doc -Scope $Scope -NoElevate:$NoElevate -NoRestartExplorer:$NoRestartExplorer
    }
    'rollback' {
        if ($Generation -lt 1) { throw 'rollback requires a generation number (see: winpkgs generations)' }
        Invoke-WinPkgsRollback -Generation $Generation -Scope $Scope -NoRestartExplorer:$NoRestartExplorer
    }
    { $_ -in 'generations', 'status' } {
        Get-WinPkgsGeneration | Format-Table -AutoSize
    }
}
