<#
    winpkgs/environment - one user environment variable, set exactly. Registry
    underneath (HKCU\Environment), plus the WM_SETTINGCHANGE broadcast that
    makes new processes see it. PATH is winpkgs/path's job: that one appends.

    properties: name, value, key (default HKCU\Environment)
#>

function Get-WinPkgsEnvironmentTarget {
    param([hashtable]$Properties)
    $key = if ($Properties['key']) { $Properties['key'] } else { 'HKCU\Environment' }
    return @{ key = $key; name = [string]$Properties['name'] }
}

function Get-WinPkgsEnvironment {
    param([hashtable]$Properties, [hashtable]$Context)
    $t = Get-WinPkgsEnvironmentTarget -Properties $Properties
    return (Get-WinPkgsRegistryValue -Properties @{ key = $t.key; name = $t.name } -Context $Context)
}

function Test-WinPkgsEnvironment {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if (-not $Current['exists']) { return $false }
    if ($Current['type'] -notin 'String', 'ExpandString') { return $false }
    return ([string]$Current['value'] -ceq [string]$Properties['value'])
}

function Set-WinPkgsEnvironment {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $t = Get-WinPkgsEnvironmentTarget -Properties $Properties
    $value = [string]$Properties['value']
    # A value that references other variables must be REG_EXPAND_SZ or Windows hands it out unexpanded.
    $kind = if ($value -match '%[^%]+%') { 'ExpandString' } else { 'String' }
    Write-WinPkgsRegistryValue -Key $t.key -Name $t.name -Kind $kind -Value $value
    if ($t.key -match '\\Environment$') { Send-WinPkgsEnvironmentChange }
}

function Restore-WinPkgsEnvironment {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $t = Get-WinPkgsEnvironmentTarget -Properties $Properties
    Restore-WinPkgsRegistryValue -Properties @{ key = $t.key; name = $t.name } -Before $Before -Context $Context
    if ($t.key -match '\\Environment$') { Send-WinPkgsEnvironmentChange }
}

function Format-WinPkgsEnvironmentChange {
    param([hashtable]$Properties, [hashtable]$Current)
    if (-not $Current['exists']) { return "absent -> $($Properties['value'])" }
    if ([string]$Current['value'] -cne [string]$Properties['value']) { return "$($Current['value']) -> $($Properties['value'])" }
    return "= $($Current['value'])"
}

Register-WinPkgsResource -Type 'winpkgs/environment' `
    -Get 'Get-WinPkgsEnvironment' `
    -Test 'Test-WinPkgsEnvironment' `
    -Set 'Set-WinPkgsEnvironment' `
    -Restore 'Restore-WinPkgsEnvironment' `
    -Describe 'Format-WinPkgsEnvironmentChange'
