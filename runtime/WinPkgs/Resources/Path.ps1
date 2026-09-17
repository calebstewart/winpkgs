<#
    winpkgs/path - a directory that must be present on a PATH-style registry
    value (by default the user's PATH in HKCU\Environment). PATH is a merge, not
    a set: the entry is appended if missing and everything else is left alone.

    properties: dir, key (default HKCU\Environment), name (default Path)
#>

function Get-WinPkgsPathTarget {
    param([hashtable]$Properties)
    $key = if ($Properties['key']) { $Properties['key'] } else { 'HKCU\Environment' }
    $name = if ($Properties['name']) { $Properties['name'] } else { 'Path' }
    return @{ key = $key; name = $name }
}

function ConvertTo-WinPkgsPathKey {
    # Comparison form: expanded, trailing separators dropped, case folded.
    param([string]$Dir)
    return [Environment]::ExpandEnvironmentVariables($Dir).TrimEnd('\', '/').ToLowerInvariant()
}

function Send-WinPkgsEnvironmentChange {
    # Tell running shells the user environment changed, so new processes see the PATH.
    Send-WinPkgsBroadcast -Message 0x001A -Param 'Environment'   # WM_SETTINGCHANGE
}

function Get-WinPkgsPath {
    param([hashtable]$Properties, [hashtable]$Context)
    $t = Get-WinPkgsPathTarget -Properties $Properties
    $current = Get-WinPkgsRegistryValue -Properties @{ key = $t.key; name = $t.name } -Context $Context
    if ($current['exists']) {
        $current['entries'] = @([string]$current['value'] -split ';' | Where-Object { $_ -ne '' })
    }
    return $current
}

function Test-WinPkgsPath {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    $want = ConvertTo-WinPkgsPathKey -Dir $Properties['dir']
    foreach ($e in @($Current['entries'])) {
        if ((ConvertTo-WinPkgsPathKey -Dir $e) -eq $want) { return $true }
    }
    return $false
}

function Set-WinPkgsPath {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $t = Get-WinPkgsPathTarget -Properties $Properties
    # Read the value again rather than trusting $Current. PATH is the one value
    # several resources of an apply write in turn -- one per directory -- and
    # $Current is the snapshot the plan took before any of them ran, so
    # rebuilding from it would drop whatever the previous one appended.
    $fresh = Get-WinPkgsPath -Properties $Properties -Context $Context
    # Not `$x = if (...) { @(...) }`: assignment from an if-statement unrolls a
    # one-element array to a scalar, and += then concatenates strings.
    [string[]]$entries = @()
    if ($fresh['exists']) { $entries = @($fresh['entries']) }
    $entries += [string]$Properties['dir']
    # Keep the kind the value already has; a fresh value is ExpandString so %VAR% entries work.
    $kind = if ($fresh['exists'] -and $fresh['type'] -in 'String', 'ExpandString') { $fresh['type'] } else { 'ExpandString' }
    Write-WinPkgsRegistryValue -Key $t.key -Name $t.name -Kind $kind -Value ($entries -join ';')
    if ($t.key -match '\\Environment$') { Send-WinPkgsEnvironmentChange }
}

function Format-WinPkgsPathChange {
    param([hashtable]$Properties, [hashtable]$Current)
    if (-not $Current['exists']) { return "new value with $($Properties['dir'])" }
    return "append $($Properties['dir'])"
}

Register-WinPkgsResource -Type 'winpkgs/path' `
    -Get 'Get-WinPkgsPath' `
    -Test 'Test-WinPkgsPath' `
    -Set 'Set-WinPkgsPath' `
    -Describe 'Format-WinPkgsPathChange'
