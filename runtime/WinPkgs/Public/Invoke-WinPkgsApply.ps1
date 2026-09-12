function Invoke-WinPkgsApply {
    <#
    .SYNOPSIS
        Converge the machine (a system document) or the user (a home document)
        to the document.

    .DESCRIPTION
        A system configuration is applied elevated, by construction: from an
        unelevated session the whole apply runs once in an elevated child (one
        UAC prompt), and only if there is something to change. A home
        configuration is applied in this process as this user and never
        elevates. Every change is journaled into a new generation before it is
        made, so a crash mid-apply still leaves a rollback record. Afterwards
        the document's generation policy is applied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Document,
        # System: report pending changes instead of prompting for elevation.
        [switch]$NoElevate,
        [switch]$NoRestartExplorer
    )

    $kind = $Document['kind']
    $elevated = Test-WinPkgsElevated

    if ($kind -eq 'system' -and -not $elevated) {
        # Planning needs no rights; elevate only for a real change.
        $pending = @(Get-WinPkgsPlan -Document $Document | Where-Object { $_.Action -ne 'noop' })
        if ($pending.Count -eq 0) {
            Write-Host '[system] already in desired state'
            return
        }
        if ($NoElevate) {
            Write-Warning "[system] $($pending.Count) change(s) pending; not applied because -NoElevate was given:"
            $pending | Format-WinPkgsPlan
            return
        }
        Invoke-WinPkgsElevated -Label 'system' -RuntimeArgs @('apply', '-Config', $Document['path'], '-NoRestartExplorer')
        return
    }

    $plan = @(Get-WinPkgsPlan -Document $Document)
    $changes = @($plan | Where-Object { $_.Action -ne 'noop' })
    $touchesExplorer = $false
    if ($changes.Count -eq 0) {
        Write-Host "[$kind] already in desired state"
    } elseif (Invoke-WinPkgsChanges -Kind $kind -Changes $changes -Document $Document) {
        $touchesExplorer = $true
    }

    # What this apply, or an earlier one, had to move aside because it was in
    # use. A service restarted onto a new binary has let go of the old by now.
    Clear-WinPkgsTrash -Kind $kind

    # Generation policy: keep the newest N, drop the rest (optionally only the
    # old ones). Runs even on a no-op apply, so a policy change takes effect
    # without waiting for a real change.
    $policy = if ($Document['settings']) { $Document['settings']['generations'] } else { $null }
    if ($policy) {
        $removed = @(Invoke-WinPkgsGarbageCollect -Kind $kind -Keep ([int]$policy['keep']) -OlderThan ([string]$policy['deleteOlderThan']))
        if ($removed.Count -gt 0) {
            Write-Host "[$kind] removed generation(s) $(($removed | ForEach-Object Generation) -join ', ') per winpkgs.generations"
        }
    }

    # The shell is the user's; only a home configuration restarts it.
    if ($kind -eq 'home' -and $touchesExplorer -and -not $NoRestartExplorer) { Restart-WinPkgsExplorer }

    # The machine is nobody's to restart from here. Say what needs one and let
    # the caller decide; winpkgs.ps1 turns it into an exit code.
    Write-WinPkgsRestartNotice -Kind $kind
}

function Invoke-WinPkgsChanges {
    <#
    .SYNOPSIS
        Apply a document's changes as a new generation of its kind, journaling
        each change before it is made. Returns whether any of them wants an
        Explorer restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][object[]]$Changes,
        [Parameter(Mandatory)][hashtable]$Document
    )

    $symbols = @{ create = '+'; update = '~'; delete = '-'; remove = '-' }
    $state = Read-WinPkgsState -Kind $Kind
    $gen = New-WinPkgsGeneration -Kind $Kind -State $state -ConfigPath $Document['path']
    $ctx = @{
        Root          = $Document['root']
        State         = $state
        Kind          = $Kind
        Substitutions = Resolve-WinPkgsSubstitutions -Document $Document
    }
    $touchesExplorer = $false
    Write-Host "[$Kind] generation $($gen.number): $($Changes.Count) change(s)"

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
            if ($props['restartMachine']) { Set-WinPkgsRestartRequired -Because $c.Id }
            Save-WinPkgsJournal -Generation $gen
        }
    } finally {
        Save-WinPkgsJournal -Generation $gen
        Save-WinPkgsState -Kind $Kind -State $state
    }

    return $touchesExplorer
}
