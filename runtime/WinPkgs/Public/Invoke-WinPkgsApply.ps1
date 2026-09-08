function Invoke-WinPkgsApply {
    <#
    .SYNOPSIS
        Converge the machine to the document.

    .DESCRIPTION
        User-scope resources are applied in this process. With -Scope auto (the
        default) and no elevation, machine-scope drift triggers exactly one
        elevated child process. Every change is journaled into a new generation
        before it is made, so a crash mid-apply still leaves a rollback record.
        Afterwards the document's generation policy is applied to each scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Document,
        [ValidateSet('auto', 'user', 'machine')][string]$Scope = 'auto',
        [switch]$NoElevate,
        [switch]$NoRestartExplorer
    )

    $elevated = Test-WinPkgsElevated
    switch ($Scope) {
        'user'    { $scopes = @('user') }
        'machine' {
            if (-not $elevated) { throw 'Machine scope requires an elevated session (or run with -Scope auto and accept the UAC prompt)' }
            $scopes = @('machine')
        }
        'auto'    { $scopes = if ($elevated) { @('user', 'machine') } else { @('user') } }
    }

    $plan = @(Get-WinPkgsPlan -Document $Document -Scope $scopes)
    $needsExplorer = $false
    $genPolicy = if ($Document['settings']) { $Document['settings']['generations'] } else { $null }

    foreach ($s in $scopes) {
        $changes = @($plan | Where-Object { $_.Scope -eq $s -and $_.Action -ne 'noop' })
        if ($changes.Count -eq 0) {
            Write-Host "[$s] already in desired state"
        } elseif (Invoke-WinPkgsScopeChanges -Scope $s -Changes $changes -Document $Document) {
            $needsExplorer = $true
        }

        # Generation policy: keep the newest N, drop the rest (optionally only
        # the old ones). Runs even on a no-op apply, so a policy change takes
        # effect without waiting for a real change.
        if ($genPolicy) {
            $removed = @(Invoke-WinPkgsGarbageCollect -Scope $s -Keep ([int]$genPolicy['keep']) -OlderThan ([string]$genPolicy['deleteOlderThan']))
            if ($removed.Count -gt 0) {
                Write-Host "[$s] removed generation(s) $(($removed | ForEach-Object Generation) -join ', ') per winpkgs.generations"
            }
        }
    }

    if ($Scope -eq 'auto' -and -not $elevated) {
        $machine = @(Get-WinPkgsPlan -Document $Document -Scope machine | Where-Object { $_.Action -ne 'noop' })
        if ($machine.Count -gt 0) {
            if ($NoElevate) {
                Write-Warning "[machine] $($machine.Count) change(s) pending; skipped because -NoElevate was given:"
                $machine | Format-WinPkgsPlan
            } else {
                Invoke-WinPkgsElevated -Label 'machine' -RuntimeArgs @(
                    'apply', '-Config', $Document['path'], '-Scope', 'machine', '-NoRestartExplorer'
                )
                foreach ($m in $machine) {
                    if ($m.Resource['properties']['restartExplorer']) { $needsExplorer = $true }
                }
            }
        }
    }

    if ($needsExplorer -and -not $NoRestartExplorer) { Restart-WinPkgsExplorer }
}

function Invoke-WinPkgsScopeChanges {
    <#
    .SYNOPSIS
        Apply one scope's changes as a new generation, journaling each change
        before it is made. Returns whether any of them wants an Explorer restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('user', 'machine')][string]$Scope,
        [Parameter(Mandatory)][object[]]$Changes,
        [Parameter(Mandatory)][hashtable]$Document
    )

    $symbols = @{ create = '+'; update = '~'; delete = '-'; remove = '-' }
    $state = Read-WinPkgsState -Scope $Scope
    $gen = New-WinPkgsGeneration -Scope $Scope -State $state -ConfigPath $Document['path']
    $ctx = @{ Root = $Document['root']; State = $state; Scope = $Scope }
    $touchesExplorer = $false
    Write-Host "[$Scope] generation $($gen.number): $($Changes.Count) change(s)"

    try {
        foreach ($c in $Changes) {
            $r = $c.Resource
            $props = $r['properties']
            Write-Host ("  {0} {1} {2}" -f $symbols[$c.Action], $c.Type, $c.Id) -NoNewline
            if ($c.Detail) { Write-Host "  ($($c.Detail))" -ForegroundColor DarkGray } else { Write-Host '' }

            $before = $c.Current
            if ($null -eq $before) {
                $before = Invoke-WinPkgsResource -Type $c.Type -Operation Get -Properties $props -Context $ctx
            }
            $backupDir = Join-Path $gen.dir ('files\{0}' -f $gen.entries.Count)
            $extra = Invoke-WinPkgsResource -Type $c.Type -Operation Backup -Properties $props -Current $before -Context $ctx -BackupDir $backupDir
            $record = @{}
            foreach ($k in $before.Keys) { $record[$k] = $before[$k] }
            foreach ($k in $extra.Keys) { $record[$k] = $extra[$k] }

            if ($c.Action -eq 'remove') {
                # Prune is "restore to not there". What is pruned was owned, and a
                # rollback that brings it back must own it again.
                $record['owned'] = $true
                Invoke-WinPkgsResource -Type $c.Type -Operation Restore -Properties $props -Before @{ exists = $false } -Context $ctx | Out-Null
            } else {
                Invoke-WinPkgsResource -Type $c.Type -Operation Set -Properties $props -Current $before -Context $ctx | Out-Null
            }

            $gen.entries.Add(@{ resource = $r; action = $c.Action; before = $record })
            if ($props['restartExplorer']) { $touchesExplorer = $true }
            Save-WinPkgsJournal -Generation $gen
        }
    } finally {
        Save-WinPkgsJournal -Generation $gen
        Save-WinPkgsState -Scope $Scope -State $state
    }

    return $touchesExplorer
}
