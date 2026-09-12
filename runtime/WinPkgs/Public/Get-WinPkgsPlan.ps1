function Get-WinPkgsPlan {
    <#
    .SYNOPSIS
        Compare every resource in the document against the machine. Read-only.

    .OUTPUTS
        One object per resource with Action in create | update | delete | noop,
        plus `remove` entries for ledger-owned things no longer declared.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Document)

    $kind = $Document['kind']
    $ctx = @{ Root = $Document['root']; Substitutions = Resolve-WinPkgsSubstitutions -Document $Document; Kind = $kind }

    # Activations react to the rest of the apply, pruning included, so they
    # are planned -- and applied -- last.
    $isActivation = { param($r) $r['type'] -eq 'winpkgs/activation' }
    $resources = @($Document['resources'])
    foreach ($r in @($resources | Where-Object { -not (& $isActivation $_) })) {
        Get-WinPkgsPlanEntry -Resource $r -Kind $kind -Context $ctx
    }

    # Prune: what winpkgs installed or created that the document no longer
    # declares. Ledger-driven, so nothing pre-existing is ever removed.
    $settings = $Document['settings']
    $prune = if ($settings) { $settings['prune'] } else { $null }
    if ($prune) {
        $state = Read-WinPkgsState -Kind $kind
        $resources = @($Document['resources'])
        $scope = Get-WinPkgsKindScope -Kind $kind

        if ($prune['winget']) {
            $declared = @($resources | Where-Object { $_['type'] -eq 'winpkgs/winget' } | ForEach-Object { $_['id'] })
            foreach ($id in @($state['owned']['winget'])) {
                if ($id -in $declared) { continue }
                [pscustomobject]@{
                    Type     = 'winpkgs/winget'
                    Id       = $id
                    Kind     = $kind
                    Action   = 'remove'
                    Detail   = 'installed by winpkgs, no longer declared'
                    Resource = @{
                        type = 'winpkgs/winget'; id = $id; scope = $scope
                        properties = @{ id = $id; version = $null; source = 'winget'; scope = $scope }
                    }
                    Current  = $null
                }
            }
        }

        if ($prune['files']) {
            $declared = @($resources | Where-Object { $_['type'] -eq 'winpkgs/file' } | ForEach-Object { ConvertTo-WinPkgsPathKey -Dir $_['properties']['target'] })
            foreach ($target in @($state['owned']['files'])) {
                if ((ConvertTo-WinPkgsPathKey -Dir $target) -in $declared) { continue }
                [pscustomobject]@{
                    Type     = 'winpkgs/file'
                    Id       = $target
                    Kind     = $kind
                    Action   = 'remove'
                    Detail   = 'created by winpkgs, no longer declared'
                    Resource = @{
                        type = 'winpkgs/file'; id = $target; scope = $scope
                        properties = @{ target = $target; source = $null }
                    }
                    Current  = $null
                }
            }

            # A font's files are no longer in the closure once its package has
            # left the configuration; the ledger says what they were.
            $declared = @($resources | Where-Object { $_['type'] -eq 'winpkgs/font' } | ForEach-Object { $_['id'] })
            $fonts = $state['owned']['fonts']
            foreach ($name in @($fonts.Keys | Sort-Object)) {
                if ($name -in $declared) { continue }
                [pscustomobject]@{
                    Type     = 'winpkgs/font'
                    Id       = $name
                    Kind     = $kind
                    Action   = 'remove'
                    Detail   = 'installed by winpkgs, no longer declared'
                    Resource = @{
                        type = 'winpkgs/font'; id = $name; scope = $scope
                        properties = @{ name = $name; source = $null; scope = $scope; files = @($fonts[$name]) }
                    }
                    Current  = $null
                }
            }
        }

        if ($prune['services']) {
            $declared = @($resources | Where-Object { $_['type'] -eq 'winpkgs/service' } | ForEach-Object { $_['properties']['name'] })
            foreach ($name in @($state['owned']['services'])) {
                if ($name -in $declared) { continue }
                [pscustomobject]@{
                    Type     = 'winpkgs/service'
                    Id       = "Service $name"
                    Kind     = $kind
                    Action   = 'remove'
                    Detail   = 'created by winpkgs, no longer declared'
                    Resource = @{
                        type = 'winpkgs/service'; id = "Service $name"; scope = $scope
                        properties = @{ name = $name }
                    }
                    Current  = $null
                }
            }
        }
    }

    foreach ($r in @($resources | Where-Object { & $isActivation $_ })) {
        Get-WinPkgsPlanEntry -Resource $r -Kind $kind -Context $ctx
    }
}

function Get-WinPkgsPlanEntry {
    # One declared resource against the machine: Get, Test, and what to do.
    param([hashtable]$Resource, [string]$Kind, [hashtable]$Context)
    $props = $Resource['properties']

    $current = Invoke-WinPkgsResource -Type $Resource['type'] -Operation Get -Properties $props -Context $Context
    $inState = Invoke-WinPkgsResource -Type $Resource['type'] -Operation Test -Properties $props -Current $current -Context $Context

    if ($inState) { $action = 'noop' }
    elseif ($props['type'] -eq 'Absent') { $action = 'delete' }
    elseif ($current['exists']) { $action = 'update' }
    else { $action = 'create' }

    [pscustomobject]@{
        Type     = $Resource['type']
        Id       = $Resource['id']
        Kind     = $Kind
        Action   = $action
        Detail   = Invoke-WinPkgsResource -Type $Resource['type'] -Operation Describe -Properties $props -Current $current
        Resource = $Resource
        Current  = $current
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
            $line = '{0} [{1}] {2} {3}' -f $symbols[$e.Action], $e.Kind, $e.Type, $e.Id
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
