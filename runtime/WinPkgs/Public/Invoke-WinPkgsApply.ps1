function Invoke-WinPkgsApply {
    <#
    .SYNOPSIS
        Converge the machine to the document.

    .DESCRIPTION
        User-scope resources are applied in this process. With -Scope auto (the
        default) and no elevation, machine-scope drift triggers exactly one
        elevated child process. Every change is journaled into a new generation
        before it is made, so a crash mid-apply still leaves a rollback record.
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
    $symbols = @{ create = '+'; update = '~'; delete = '-'; remove = '-' }

    foreach ($s in $scopes) {
        $changes = @($plan | Where-Object { $_.Scope -eq $s -and $_.Action -ne 'noop' })
        if ($changes.Count -eq 0) {
            Write-Host "[$s] already in desired state"
            continue
        }

        $state = Read-WinPkgsState -Scope $s
        $gen = New-WinPkgsGeneration -Scope $s -State $state -ConfigPath $Document['path']
        $ctx = @{ Root = $Document['root']; State = $state; Scope = $s }
        Write-Host "[$s] generation $($gen.number): $($changes.Count) change(s)"

        try {
            foreach ($c in $changes) {
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
                    # Prune is "restore to not-installed".
                    Invoke-WinPkgsResource -Type $c.Type -Operation Restore -Properties $props -Before @{ exists = $false } -Context $ctx
                } else {
                    Invoke-WinPkgsResource -Type $c.Type -Operation Set -Properties $props -Current $before -Context $ctx
                }

                $gen.entries.Add(@{ resource = $r; action = $c.Action; before = $record })
                if ($props['restartExplorer']) { $needsExplorer = $true }
                Save-WinPkgsJournal -Generation $gen
            }
        } finally {
            Save-WinPkgsJournal -Generation $gen
            Save-WinPkgsState -Scope $s -State $state
        }
    }

    if ($Scope -eq 'auto' -and -not $elevated) {
        $machine = @(Get-WinPkgsPlan -Document $Document -Scope machine | Where-Object { $_.Action -ne 'noop' })
        if ($machine.Count -gt 0) {
            if ($NoElevate) {
                Write-Warning "[machine] $($machine.Count) change(s) pending; skipped because -NoElevate was given:"
                $machine | Format-WinPkgsPlan
            } else {
                Invoke-WinPkgsElevatedApply -Document $Document
                foreach ($m in $machine) {
                    if ($m.Resource['properties']['restartExplorer']) { $needsExplorer = $true }
                }
            }
        }
    }

    if ($needsExplorer -and -not $NoRestartExplorer) { Restart-WinPkgsExplorer }
}
