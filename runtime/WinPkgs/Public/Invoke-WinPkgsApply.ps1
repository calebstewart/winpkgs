function Invoke-WinPkgsApply {
    <#
    .SYNOPSIS
        Switch the machine (a system document) or the user (a home document) to
        the document's configuration, converging to it.

    .DESCRIPTION
        A generation is a closure that was applied -- the document, the files
        and fonts it names, and the runtime that understands them -- kept in the
        generation's directory. Applying a closure that is not the current
        generation's keeps it as a new generation and makes that one current,
        even when nothing on the machine has to change, the way a profile link
        moves to a new system. Applying the current generation's closure again
        converges whatever drifted and records nothing new. -Generation N
        applies the closure generation N keeps, as N: what rollback runs, in
        that generation's own runtime. Either way the resources are applied
        from the kept copy, not from where the closure was built -- what is
        applied is the file at the document's path and what lies beside it,
        as they are on disk.

        A system configuration is applied elevated, by construction: from an
        unelevated session the whole apply runs once in an elevated child (one
        UAC prompt), and only when there is something to change or another
        generation to switch to. A home configuration is applied in this process
        as this user and never elevates. Every change is journaled before it is
        made, so a crash mid-apply still leaves a record of it. Afterwards the
        document's generation policy is applied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Document,
        # Apply as this existing generation; the document must be the one it keeps.
        [int]$Generation = 0,
        # System: report pending changes instead of prompting for elevation.
        [switch]$NoElevate,
        [switch]$NoRestartExplorer
    )

    $kind = $Document['kind']
    $manifest = Get-WinPkgsClosureManifest -Path $Document['path']
    $target = Resolve-WinPkgsTargetGeneration -Kind $kind -Manifest $manifest -Generation $Generation
    $switching = $target.new -or $target.number -ne $target.current

    if ($kind -eq 'system' -and -not (Test-WinPkgsElevated)) {
        # Planning needs no rights; elevate only for a change or a switch.
        $planned = if ($target.new) { $Document } else { Read-WinPkgsGenerationDocument -Kind system -Number $target.number }
        $pending = @(Get-WinPkgsPlan -Document $planned | Where-Object { $_.Action -ne 'noop' })
        if ($pending.Count -eq 0 -and -not $switching) {
            Write-Host "[system] already in desired state (generation $($target.number))"
            return
        }
        if ($NoElevate) {
            Write-Warning "[system] $(Format-WinPkgsTarget -Target $target -Changes $pending.Count); not applied because -NoElevate was given"
            if ($pending.Count -gt 0) { $pending | Format-WinPkgsPlan }
            return
        }
        $forward = @('apply', '-Config', $Document['path'], '-NoRestartExplorer')
        if ($Generation -gt 0) { $forward += @('-Generation', "$Generation") }
        Invoke-WinPkgsElevated -Label 'system' -RuntimeArgs $forward
        return
    }
    if ($kind -eq 'system') { Protect-WinPkgsStateDir -Path (Get-WinPkgsStateDir -Kind system) }

    if ($target.new) {
        New-WinPkgsGeneration -Kind $kind -Path $Document['path'] -Manifest $manifest -Number $target.number | Out-Null
    }
    # Before anything changes, as a profile link moves before the system is
    # activated: an apply that fails part-way is on this generation, and going
    # back means going to the one before it.
    if ($switching) { Set-WinPkgsCurrentGeneration -Kind $kind -Number $target.number }

    $kept = Read-WinPkgsGenerationDocument -Kind $kind -Number $target.number
    $changes = @(Get-WinPkgsPlan -Document $kept | Where-Object { $_.Action -ne 'noop' })
    $touchesExplorer = $false
    if ($changes.Count -eq 0 -and -not $switching) {
        Write-Host "[$kind] already in desired state (generation $($target.number))"
    } else {
        Write-Host "[$kind] $(Format-WinPkgsTarget -Target $target -Changes $changes.Count)"
        $run = $null
        if ($target.new) {
            # A new generation's first run is its record, changes or not.
            $run = New-WinPkgsRun -Kind $kind -Number $target.number
            Save-WinPkgsJournal -Run $run
        } elseif ($changes.Count -gt 0) {
            $run = New-WinPkgsRun -Kind $kind -Number $target.number -Label $(if ($Generation -gt 0) { 'rollback' } else { 'apply' })
        }
        if ($changes.Count -gt 0) {
            $touchesExplorer = Invoke-WinPkgsChanges -Kind $kind -Changes $changes -Document $kept -Run $run
        }
    }

    # What this apply, or an earlier one, had to move aside because it was in
    # use. A service restarted onto a new binary has let go of the old by now.
    Clear-WinPkgsTrash -Kind $kind

    # Generation policy: keep the newest N, drop the rest (optionally only the
    # old ones). Runs even on a no-op apply, so a policy change takes effect
    # without waiting for a real change.
    $policy = if ($kept['settings']) { $kept['settings']['generations'] } else { $null }
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

function Format-WinPkgsTarget {
    # What an apply is about to do, in a line: "generation 12: 3 change(s)".
    param([Parameter(Mandatory)][hashtable]$Target, [int]$Changes)
    $what = if ($Changes -gt 0) { "$Changes change(s)" } else { 'nothing on the machine to change' }
    if ($Target.new) { return "generation $($Target.number): $what" }
    if ($Target.number -ne $Target.current) { return "switching to generation $($Target.number): $what" }
    return "generation $($Target.number) again: $what"
}

function Invoke-WinPkgsChanges {
    <#
    .SYNOPSIS
        Make a document's changes as one run of a generation, journaling each
        change before it is made. Returns whether any of them wants an Explorer
        restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][object[]]$Changes,
        [Parameter(Mandatory)][hashtable]$Document,
        [Parameter(Mandatory)][hashtable]$Run
    )

    $symbols = @{ create = '+'; update = '~'; delete = '-'; remove = '-' }
    $state = Read-WinPkgsState -Kind $Kind
    $ctx = @{
        Root          = $Document['root']
        State         = $state
        Kind          = $Kind
        Substitutions = Resolve-WinPkgsSubstitutions -Document $Document
    }
    $touchesExplorer = $false

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
            $backupDir = Join-Path $Run.backups $Run.entries.Count
            $extra = Invoke-WinPkgsResource -Type $c.Type -Operation Backup -Properties $props -Current $before -Context $ctx -BackupDir $backupDir
            $record = @{}
            foreach ($k in $before.Keys) { $record[$k] = $before[$k] }
            foreach ($k in $extra.Keys) { $record[$k] = $extra[$k] }

            if ($c.Action -eq 'remove') {
                # Prune is "restore to not there", and what is pruned was owned.
                $record['owned'] = $true
                Invoke-WinPkgsResource -Type $c.Type -Operation Restore -Properties $props -Before @{ exists = $false } -Context $ctx | Out-Null
            } else {
                Invoke-WinPkgsResource -Type $c.Type -Operation Set -Properties $props -Current $before -Context $ctx | Out-Null
            }

            $Run.entries.Add(@{ resource = $r; action = $c.Action; before = $record })
            if ($props['restartExplorer']) { $touchesExplorer = $true }
            if ($props['restartMachine']) { Set-WinPkgsRestartRequired -Because $c.Id }
            Save-WinPkgsJournal -Run $Run
        }
    } finally {
        Save-WinPkgsJournal -Run $Run
        Save-WinPkgsState -Kind $Kind -State $state
    }

    return $touchesExplorer
}
