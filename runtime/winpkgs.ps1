#Requires -Version 5.1
<#
.SYNOPSIS
    winpkgs runtime entry point: converge a Windows machine (system document)
    or a user (home document) to a desired-state document.

    Runs under pwsh 7 or Windows PowerShell 5.1. A system document is applied
    elevated -- from an unelevated session the runtime re-launches itself once
    under an unpackaged host (see Get-WinPkgsElevationHost). A home document
    never elevates.

.DESCRIPTION
    plan         Show what apply would change. Needs no elevation.
    apply        Converge to the document.
    rollback     Undo a generation: rollback -Kind system|home N.
    generations  List recorded generations (both kinds, or -Kind).
    gc           Delete old generations: -Kind, -Keep N, -OlderThan 30d, -DryRun.

.EXAMPLE
    .\winpkgs.ps1 apply -Config \\wsl.localhost\NixOS\nix\store\...-winpkgs-desktop\config.json
.EXAMPLE
    .\winpkgs.ps1 rollback -Kind home 3
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'apply', 'rollback', 'generations', 'status', 'gc')]
    [string]$Command = 'plan',

    [Alias('c')]
    [string]$Config,

    # Which state to act on for rollback / generations / gc. plan and apply
    # take it from the document.
    [ValidateSet('auto', 'system', 'home')]
    [string]$Kind = 'auto',

    # rollback: the generation to undo. Positional, so `rollback -Kind home 12` works.
    [Parameter(Position = 1)]
    [int]$Generation = 0,

    # gc: keep this many of the newest generations per kind ...
    [int]$Keep = 10,
    # ... and beyond those, delete only generations older than this (30d, 12h, 90m).
    [string]$OlderThan,
    # gc: list what would go without deleting it.
    [switch]$DryRun,

    # apply (system): report pending changes instead of prompting for UAC.
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

$kinds = if ($Kind -eq 'auto') { @('system', 'home') } else { @($Kind) }

switch ($Command) {
    'plan' {
        Get-WinPkgsPlan -Document (Get-Document) | Format-WinPkgsPlan -ShowUnchanged:$ShowUnchanged
    }
    'apply' {
        Invoke-WinPkgsApply -Document (Get-Document) -NoElevate:$NoElevate -NoRestartExplorer:$NoRestartExplorer
    }
    'rollback' {
        if ($Kind -eq 'auto') { throw 'rollback needs -Kind system or -Kind home: each keeps its own generations' }
        if ($Generation -lt 1) { throw "rollback requires a generation number (see: winpkgs $Kind generations)" }
        Invoke-WinPkgsRollback -Kind $Kind -Generation $Generation -NoRestartExplorer:$NoRestartExplorer
    }
    { $_ -in 'generations', 'status' } {
        Get-WinPkgsGeneration -Kind $kinds | Format-Table -AutoSize
    }
    'gc' {
        $common = @{ Keep = $Keep }
        if ($OlderThan) { $common['OlderThan'] = $OlderThan }
        foreach ($k in $kinds) {
            if ($k -eq 'system' -and -not (Test-WinPkgsElevated)) {
                # Deleting from %ProgramData% needs elevation; only ask if there is something to delete.
                $pending = @(Invoke-WinPkgsGarbageCollect -Kind system -DryRun @common)
                if ($pending.Count -eq 0) { Write-Host '[system] nothing to remove'; continue }
                if ($DryRun) { $pending | ForEach-Object { Write-Host "[system] would remove generation $($_.Generation)" }; continue }
                $forward = @('gc', '-Kind', 'system', '-Keep', "$Keep")
                if ($OlderThan) { $forward += @('-OlderThan', $OlderThan) }
                Invoke-WinPkgsElevated -Label 'system' -RuntimeArgs $forward
                continue
            }
            $removed = @(Invoke-WinPkgsGarbageCollect -Kind $k -DryRun:$DryRun @common)
            if ($removed.Count -eq 0) { Write-Host "[$k] nothing to remove" }
            foreach ($g in $removed) {
                Write-Host ("[{0}] {1} generation {2} ({3}, {4} change(s))" -f $k, $(if ($DryRun) { 'would remove' } else { 'removed' }), $g.Generation, $g.Started, $g.Changes)
            }
        }
    }
}
