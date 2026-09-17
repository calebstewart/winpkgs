<#
    winpkgs/pathOrder - the directories that must come first on a PATH-style
    registry value, in order. winpkgs/path says a directory is *there*; this
    says it is *ahead*, which is the only way to beat an entry winpkgs does not
    own -- System32, or whatever an installer appended.

    One resource for all of them rather than one each: "is this directory in
    front?" cannot be answered per directory, since the second one would always
    find the first ahead of it. Ordering is the property of the value, so the
    resource is too.

    Set moves entries rather than rewriting them: an equivalent entry already
    on the value keeps its own spelling and is moved to the front, so a
    `C:\Program Files\WinGet\Links` that winget wrote is not quietly restated as
    `%ProgramFiles%\WinGet\Links`. Only a directory with no equivalent is added.

    Nothing here is owned or pruned, as with winpkgs/path: an order asserted is
    not undone by dropping the entry from the configuration, and a rollback to a
    generation that never led it does not put the old order back. What the value
    was before is in that generation's journal.

    properties: dirs (ordered), key (default HKCU\Environment), name (default Path)
#>

function Get-WinPkgsPathOrder {
    param([hashtable]$Properties, [hashtable]$Context)
    return (Get-WinPkgsPath -Properties $Properties -Context $Context)
}

function Test-WinPkgsPathOrder {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    $want = @(@($Properties['dirs']) | ForEach-Object { ConvertTo-WinPkgsPathKey -Dir $_ })
    $have = @(@($Current['entries']) | ForEach-Object { ConvertTo-WinPkgsPathKey -Dir $_ })
    if ($have.Count -lt $want.Count) { return $false }
    # A strict prefix: anything else leaves an entry winpkgs does not own ahead
    # of one it was asked to put first, which is the whole point of the type.
    for ($i = 0; $i -lt $want.Count; $i++) {
        if ($have[$i] -ne $want[$i]) { return $false }
    }
    return $true
}

function Set-WinPkgsPathOrder {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $t = Get-WinPkgsPathTarget -Properties $Properties
    # As winpkgs/path does, and for the same reason: the directories of this
    # apply have been appended to this value since the plan read it.
    $fresh = Get-WinPkgsPath -Properties $Properties -Context $Context
    [string[]]$entries = @()
    if ($fresh['exists']) { $entries = @($fresh['entries']) }

    [string[]]$lead = @()
    foreach ($dir in @($Properties['dirs'])) {
        $key = ConvertTo-WinPkgsPathKey -Dir $dir
        $match = @($entries | Where-Object { (ConvertTo-WinPkgsPathKey -Dir $_) -eq $key })
        # Keep the spelling the machine already has; ours only when it has none.
        if ($match.Count -gt 0) { $lead += $match[0] } else { $lead += [string]$dir }
        # Every equivalent entry goes, so leading also removes duplicates.
        $entries = @($entries | Where-Object { (ConvertTo-WinPkgsPathKey -Dir $_) -ne $key })
    }

    $kind = if ($fresh['exists'] -and $fresh['type'] -in 'String', 'ExpandString') { $fresh['type'] } else { 'ExpandString' }
    Write-WinPkgsRegistryValue -Key $t.key -Name $t.name -Kind $kind -Value (($lead + $entries) -join ';')
    if ($t.key -match '\\Environment$') { Send-WinPkgsEnvironmentChange }
}

function Format-WinPkgsPathOrderChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $dirs = @($Properties['dirs']) -join ', '
    if (-not $Current['exists']) { return "new value led by $dirs" }
    $first = @($Current['entries']) | Select-Object -First 1
    return "lead with $dirs (now $first)"
}

Register-WinPkgsResource -Type 'winpkgs/pathOrder' `
    -Get 'Get-WinPkgsPathOrder' `
    -Test 'Test-WinPkgsPathOrder' `
    -Set 'Set-WinPkgsPathOrder' `
    -Describe 'Format-WinPkgsPathOrderChange'
