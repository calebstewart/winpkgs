function Get-WinPkgsPlan {
    <#
    .SYNOPSIS
        Compare every resource in the document against the machine. Read-only.

    .OUTPUTS
        One object per resource with Action in create | update | delete | noop,
        plus `remove` entries for ledger-owned winget packages no longer declared.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Document,
        [ValidateSet('user', 'machine')][string[]]$Scope = @('user', 'machine')
    )

    $ctx = @{ Root = $Document['root'] }

    foreach ($r in @($Document['resources'])) {
        if ($r['scope'] -notin $Scope) { continue }
        $props = $r['properties']

        $current = Invoke-WinPkgsResource -Type $r['type'] -Operation Get -Properties $props -Context $ctx
        $inState = Invoke-WinPkgsResource -Type $r['type'] -Operation Test -Properties $props -Current $current -Context $ctx

        if ($inState) { $action = 'noop' }
        elseif ($props['type'] -eq 'Absent') { $action = 'delete' }
        elseif ($current['exists']) { $action = 'update' }
        else { $action = 'create' }

        [pscustomobject]@{
            Type     = $r['type']
            Id       = $r['id']
            Scope    = $r['scope']
            Action   = $action
            Detail   = Invoke-WinPkgsResource -Type $r['type'] -Operation Describe -Properties $props -Current $current
            Resource = $r
            Current  = $current
        }
    }

    # Prune: what winpkgs installed or created that the document no longer
    # declares. Ledger-driven, so nothing pre-existing is ever removed.
    $settings = $Document['settings']
    $prune = if ($settings) { $settings['prune'] } else { $null }
    if ($prune) {
        foreach ($s in $Scope) {
            $state = Read-WinPkgsState -Scope $s
            $inScope = @(@($Document['resources']) | Where-Object { $_['scope'] -eq $s })

            if ($prune['winget']) {
                $declared = @($inScope | Where-Object { $_['type'] -eq 'winpkgs/winget' } | ForEach-Object { $_['id'] })
                foreach ($id in @($state['owned']['winget'])) {
                    if ($id -in $declared) { continue }
                    [pscustomobject]@{
                        Type     = 'winpkgs/winget'
                        Id       = $id
                        Scope    = $s
                        Action   = 'remove'
                        Detail   = 'installed by winpkgs, no longer declared'
                        Resource = @{
                            type = 'winpkgs/winget'; id = $id; scope = $s
                            properties = @{ id = $id; version = $null; source = 'winget'; scope = $null }
                        }
                        Current  = $null
                    }
                }
            }

            if ($prune['files']) {
                $declared = @($inScope | Where-Object { $_['type'] -eq 'winpkgs/file' } | ForEach-Object { ConvertTo-WinPkgsPathKey -Dir $_['properties']['target'] })
                foreach ($target in @($state['owned']['files'])) {
                    if ((ConvertTo-WinPkgsPathKey -Dir $target) -in $declared) { continue }
                    [pscustomobject]@{
                        Type     = 'winpkgs/file'
                        Id       = $target
                        Scope    = $s
                        Action   = 'remove'
                        Detail   = 'created by winpkgs, no longer declared'
                        Resource = @{
                            type = 'winpkgs/file'; id = $target; scope = $s
                            properties = @{ target = $target; source = $null }
                        }
                        Current  = $null
                    }
                }
            }
        }
    }
}

function Format-WinPkgsPlan {
    <#
    .SYNOPSIS
        Print a plan in terraform style: + create, ~ update, - delete/remove, = unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)][object]$Entry,
        [switch]$ShowUnchanged
    )
    begin {
        $all = [System.Collections.Generic.List[object]]::new()
        $symbols = @{ create = '+'; update = '~'; delete = '-'; remove = '-'; noop = '=' }
        $colors = @{ create = 'Green'; update = 'Yellow'; delete = 'Red'; remove = 'Red'; noop = 'DarkGray' }
    }
    process { if ($null -ne $Entry) { $all.Add($Entry) } }
    end {
        foreach ($e in $all) {
            if ($e.Action -eq 'noop' -and -not $ShowUnchanged) { continue }
            $line = '{0} [{1}] {2} {3}' -f $symbols[$e.Action], $e.Scope, $e.Type, $e.Id
            Write-Host $line -ForegroundColor $colors[$e.Action] -NoNewline
            if ($e.Detail) { Write-Host "  ($($e.Detail))" -ForegroundColor DarkGray } else { Write-Host '' }
        }
        $counts = @{}
        foreach ($e in $all) { $counts[$e.Action] = 1 + [int]$counts[$e.Action] }
        Write-Host ''
        Write-Host ('{0} to create, {1} to update, {2} to delete, {3} to remove, {4} unchanged' -f
            [int]$counts['create'], [int]$counts['update'], [int]$counts['delete'], [int]$counts['remove'], [int]$counts['noop'])
    }
}
