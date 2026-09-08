function Invoke-WinPkgsRollback {
    <#
    .SYNOPSIS
        Undo one generation by replaying its journal in reverse.

    .DESCRIPTION
        The rollback is itself recorded as a new generation (kind = rollback),
        so it can in turn be rolled back. Registry and file restores are exact;
        package restores are best effort.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('user', 'machine')][string]$Scope,
        [Parameter(Mandatory)][int]$Generation,
        [switch]$NoRestartExplorer
    )

    $dir = Join-Path (Get-WinPkgsStateDir -Scope $Scope) ('generations\{0:D3}' -f $Generation)
    $journalPath = Join-Path $dir 'journal.json'
    if (-not (Test-Path -LiteralPath $journalPath)) {
        throw "No journal for $Scope generation $Generation ($journalPath)"
    }
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
    $entries = @($journal['entries'])
    [array]::Reverse($entries)

    if ($Scope -eq 'machine' -and -not (Test-WinPkgsElevated)) {
        # Same one-prompt elevation as apply. The child must not restart Explorer
        # (it would come back elevated); decide that here from the journal.
        Invoke-WinPkgsElevated -Label 'machine' -RuntimeArgs @(
            'rollback', '-Scope', 'machine', '-Generation', "$Generation", '-NoRestartExplorer'
        )
        $touchesExplorer = @($entries | Where-Object { $_['resource']['properties']['restartExplorer'] }).Count -gt 0
        if ($touchesExplorer -and -not $NoRestartExplorer) { Restart-WinPkgsExplorer }
        return
    }

    $state = Read-WinPkgsState -Scope $Scope
    $gen = New-WinPkgsGeneration -Scope $Scope -State $state -ConfigPath (Join-Path $dir 'config.json') -Kind "rollback of $Generation"
    $ctx = @{ Root = $dir; State = $state; Scope = $Scope }
    $needsExplorer = $false
    Write-Host "[$Scope] rolling back generation $Generation ($($entries.Count) change(s)) as generation $($gen.number)"

    try {
        foreach ($e in $entries) {
            $r = $e['resource']
            $props = $r['properties']
            Write-Host "  < $($r['type']) $($r['id'])"

            $current = Invoke-WinPkgsResource -Type $r['type'] -Operation Get -Properties $props -Context $ctx
            $backupDir = Join-Path $gen.dir ('files\{0}' -f $gen.entries.Count)
            $extra = Invoke-WinPkgsResource -Type $r['type'] -Operation Backup -Properties $props -Current $current -Context $ctx -BackupDir $backupDir
            $record = @{}
            foreach ($k in $current.Keys) { $record[$k] = $current[$k] }
            foreach ($k in $extra.Keys) { $record[$k] = $extra[$k] }

            Invoke-WinPkgsResource -Type $r['type'] -Operation Restore -Properties $props -Before $e['before'] -Context $ctx

            $gen.entries.Add(@{ resource = $r; action = 'restore'; before = $record })
            if ($props['restartExplorer']) { $needsExplorer = $true }
            Save-WinPkgsJournal -Generation $gen
        }
    } finally {
        Save-WinPkgsJournal -Generation $gen
        Save-WinPkgsState -Scope $Scope -State $state
    }

    if ($needsExplorer -and -not $NoRestartExplorer) { Restart-WinPkgsExplorer }
}
