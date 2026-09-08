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
    gc           Delete old generations: -Keep N (default 10), -OlderThan 30d, -DryRun.

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
    [ValidateSet('plan', 'apply', 'rollback', 'generations', 'status', 'gc')]
    [string]$Command = 'plan',

    [Alias('c')]
    [string]$Config,

    [ValidateSet('auto', 'user', 'machine')]
    [string]$Scope = 'auto',

    # rollback: the generation to undo. Positional, so `rollback 12` works.
    [Parameter(Position = 1)]
    [int]$Generation = 0,

    # gc: keep this many of the newest generations per scope ...
    [int]$Keep = 10,
    # ... and beyond those, delete only generations older than this (30d, 12h, 90m).
    [string]$OlderThan,
    # gc: list what would go without deleting it.
    [switch]$DryRun,

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
    'gc' {
        $scopes = if ($Scope -eq 'auto') { @('user', 'machine') } else { @($Scope) }
        $common = @{ Keep = $Keep }
        if ($OlderThan) { $common['OlderThan'] = $OlderThan }
        foreach ($s in $scopes) {
            if ($s -eq 'machine' -and -not (Test-WinPkgsElevated)) {
                # Deleting from %ProgramData% needs elevation; only ask if there is something to delete.
                $pending = @(Invoke-WinPkgsGarbageCollect -Scope machine -DryRun @common)
                if ($pending.Count -eq 0) { Write-Host '[machine] nothing to remove'; continue }
                if ($DryRun) { $pending | ForEach-Object { Write-Host "[machine] would remove generation $($_.Generation)" }; continue }
                $args = @('gc', '-Scope', 'machine', '-Keep', "$Keep")
                if ($OlderThan) { $args += @('-OlderThan', $OlderThan) }
                Invoke-WinPkgsElevated -Label 'machine' -RuntimeArgs $args
                continue
            }
            $removed = @(Invoke-WinPkgsGarbageCollect -Scope $s -DryRun:$DryRun @common)
            if ($removed.Count -eq 0) { Write-Host "[$s] nothing to remove" }
            foreach ($g in $removed) {
                Write-Host ("[{0}] {1} generation {2} ({3}, {4} change(s))" -f $s, $(if ($DryRun) { 'would remove' } else { 'removed' }), $g.Generation, $g.Started, $g.Changes)
            }
        }
    }
}
