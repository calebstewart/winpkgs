function Invoke-WinPkgsRollback {
    <#
    .SYNOPSIS
        Undo one generation of one kind by replaying its journal in reverse.

    .DESCRIPTION
        The rollback is itself recorded as a new generation of the same kind, so
        it can in turn be rolled back. Registry and file restores are exact;
        package restores are best effort. Rolling back a system generation
        elevates once, like applying one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'home')][string]$Kind,
        [Parameter(Mandatory)][int]$Generation,
        [switch]$NoRestartExplorer
    )

    $dir = Join-Path (Get-WinPkgsStateDir -Kind $Kind) ('generations\{0:D3}' -f $Generation)
    $journalPath = Join-Path $dir 'journal.json'
    if (-not (Test-Path -LiteralPath $journalPath)) {
        throw "No $Kind generation $Generation ($journalPath); see: winpkgs $Kind generations"
    }
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-WinPkgsJson
    $entries = @($journal['entries'])
    [array]::Reverse($entries)

    if ($Kind -eq 'system' -and -not (Test-WinPkgsElevated)) {
        Invoke-WinPkgsElevated -Label 'system' -RuntimeArgs @(
            'rollback', '-Kind', 'system', '-Generation', "$Generation", '-NoRestartExplorer'
        )
        return
    }
    if ($Kind -eq 'system') { Protect-WinPkgsStateDir -Path (Get-WinPkgsStateDir -Kind system) }

    $state = Read-WinPkgsState -Kind $Kind
    $gen = New-WinPkgsGeneration -Kind $Kind -State $state -ConfigPath (Join-Path $dir 'config.json') -Label "rollback of $Generation"
    $ctx = @{ Root = $dir; State = $state; Kind = $Kind }
    $touchesExplorer = $false
    Write-Host "[$Kind] rolling back generation $Generation ($($entries.Count) change(s)) as generation $($gen.number)"

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

            Invoke-WinPkgsResource -Type $r['type'] -Operation Restore -Properties $props -Before $e['before'] -Context $ctx | Out-Null

            $gen.entries.Add(@{ resource = $r; action = 'restore'; before = $record })
            if ($props['restartExplorer']) { $touchesExplorer = $true }
            Save-WinPkgsJournal -Generation $gen
        }
    } finally {
        Save-WinPkgsJournal -Generation $gen
        Save-WinPkgsState -Kind $Kind -State $state
    }

    Clear-WinPkgsTrash -Kind $Kind

    if ($Kind -eq 'home' -and $touchesExplorer -and -not $NoRestartExplorer) { Restart-WinPkgsExplorer }
}
