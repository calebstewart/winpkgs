<#
    Power, through powercfg. Three resource types, all machine scope:

      winpkgs/powerPlan     the active scheme            properties: guid
      winpkgs/powerSetting  one value of a scheme        properties: label, scheme (guid or null for the
                                                         active one), subgroup, setting (guids), ac, dc
                                                         (integers; null leaves that side alone)
      winpkgs/hibernation   whether hibernation is on    properties: enabled

    powercfg is the only honest reader: the registry holds a scheme's value
    only where it has been overridden, so a setting at its default has no key
    to read. Its output is localised, but the value lines are the last two
    and end in a hex index, and the active scheme's line carries a guid, so
    parsing looks for those rather than for words. Changing a value of the
    active scheme takes effect once the scheme is set active again, which
    Set does.

    WINPKGS_POWERCFG names a script to run instead of powercfg.exe, and
    WINPKGS_POWER_KEY redirects the hibernation flag's key (tests).
#>

$script:GuidPattern = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

function Invoke-WinPkgsPowercfg {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = if ($env:WINPKGS_POWERCFG) { $env:WINPKGS_POWERCFG } else { 'powercfg.exe' }
    $r = Invoke-WinPkgsExternal -Command $exe -Arguments $Arguments
    if ($r['failed']) { throw "powercfg $($Arguments -join ' ') failed: $($r['text'])" }
    return $r['lines']
}

function Get-WinPkgsActivePowerScheme {
    $lines = Invoke-WinPkgsPowercfg -Arguments @('/getactivescheme')
    foreach ($l in $lines) {
        if ($l -match $script:GuidPattern) { return $Matches[0].ToLowerInvariant() }
    }
    throw "Could not find the active power scheme in: $($lines -join ' ')"
}

function Format-WinPkgsPowerValue {
    # Seconds read well as minutes; other settings are small enumerations.
    param($Value)
    if ($null -eq $Value) { return '-' }
    if ($Value -eq 0) { return '0 (never)' }
    if ($Value -ge 60 -and ($Value % 60) -eq 0) { return "$($Value / 60) min" }
    return [string]$Value
}

# --- winpkgs/powerPlan ---------------------------------------------------------

function Get-WinPkgsPowerPlan {
    param([hashtable]$Properties, [hashtable]$Context)
    return @{ exists = $true; guid = Get-WinPkgsActivePowerScheme }
}

function Test-WinPkgsPowerPlan {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    return ([string]$Current['guid'] -ieq [string]$Properties['guid'])
}

function Set-WinPkgsPowerPlan {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    try {
        Invoke-WinPkgsPowercfg -Arguments @('/setactive', [string]$Properties['guid']) | Out-Null
    } catch {
        throw "$($_.Exception.Message). A scheme Windows hides (Ultimate Performance) has to exist first: powercfg /duplicatescheme $($Properties['guid'])"
    }
}

function Restore-WinPkgsPowerPlan {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    if ($Before['guid']) { Invoke-WinPkgsPowercfg -Arguments @('/setactive', [string]$Before['guid']) | Out-Null }
}

function Format-WinPkgsPowerPlanChange {
    param([hashtable]$Properties, [hashtable]$Current)
    return "$($Current['guid']) -> $($Properties['guid'])"
}

Register-WinPkgsResource -Type 'winpkgs/powerPlan' `
    -Get 'Get-WinPkgsPowerPlan' -Test 'Test-WinPkgsPowerPlan' -Set 'Set-WinPkgsPowerPlan' `
    -Restore 'Restore-WinPkgsPowerPlan' -Describe 'Format-WinPkgsPowerPlanChange'

# --- winpkgs/powerSetting ------------------------------------------------------

function Resolve-WinPkgsPowerScheme {
    param([hashtable]$Properties)
    if ($Properties['scheme']) { return ([string]$Properties['scheme']).ToLowerInvariant() }
    return Get-WinPkgsActivePowerScheme
}

function Get-WinPkgsPowerSetting {
    param([hashtable]$Properties, [hashtable]$Context)
    $scheme = Resolve-WinPkgsPowerScheme -Properties $Properties
    $lines = Invoke-WinPkgsPowercfg -Arguments @('/query', $scheme, [string]$Properties['subgroup'], [string]$Properties['setting'])
    # The current AC and DC indexes are the last two lines; each ends in hex.
    # A setting Windows hides (the button actions on a desktop) answers with
    # the header alone: unknown until Set unhides it.
    $hex = @($lines | Where-Object { $_ -match '0x[0-9a-fA-F]+\s*$' } | ForEach-Object { [Convert]::ToInt64(($_ -replace '.*0x([0-9a-fA-F]+)\s*$', '$1'), 16) })
    if ($hex.Count -lt 2) { return @{ exists = $true; scheme = $scheme; ac = $null; dc = $null; hidden = $true } }
    return @{
        exists = $true
        scheme = $scheme
        ac     = $hex[$hex.Count - 2]
        dc     = $hex[$hex.Count - 1]
        hidden = $false
    }
}

function Test-WinPkgsPowerSetting {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if ($Current['hidden']) { return $false }
    if ($null -ne $Properties['ac'] -and [int64]$Current['ac'] -ne [int64]$Properties['ac']) { return $false }
    if ($null -ne $Properties['dc'] -and [int64]$Current['dc'] -ne [int64]$Properties['dc']) { return $false }
    return $true
}

function Set-WinPkgsPowerSettingVisibility {
    param([hashtable]$Properties, [bool]$Hidden)
    $flag = if ($Hidden) { '+ATTRIB_HIDE' } else { '-ATTRIB_HIDE' }
    Invoke-WinPkgsPowercfg -Arguments @('/attributes', [string]$Properties['subgroup'], [string]$Properties['setting'], $flag) | Out-Null
}

function Write-WinPkgsPowerSetting {
    param([string]$Scheme, [hashtable]$Properties, $Ac, $Dc)
    $sub = [string]$Properties['subgroup']
    $setting = [string]$Properties['setting']
    if ($null -ne $Ac) { Invoke-WinPkgsPowercfg -Arguments @('/setacvalueindex', $Scheme, $sub, $setting, [string]$Ac) | Out-Null }
    if ($null -ne $Dc) { Invoke-WinPkgsPowercfg -Arguments @('/setdcvalueindex', $Scheme, $sub, $setting, [string]$Dc) | Out-Null }
    # A change to the active scheme is read when it is (re)activated.
    if ($Scheme -ieq (Get-WinPkgsActivePowerScheme)) { Invoke-WinPkgsPowercfg -Arguments @('/setactive', $Scheme) | Out-Null }
}

function Set-WinPkgsPowerSetting {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $scheme = Resolve-WinPkgsPowerScheme -Properties $Properties
    if ($Current -and $Current['hidden']) { Set-WinPkgsPowerSettingVisibility -Properties $Properties -Hidden $false }
    Write-WinPkgsPowerSetting -Scheme $scheme -Properties $Properties -Ac $Properties['ac'] -Dc $Properties['dc']
}

function Restore-WinPkgsPowerSetting {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $scheme = if ($Before['scheme']) { [string]$Before['scheme'] } else { Resolve-WinPkgsPowerScheme -Properties $Properties }
    # What a hidden setting held was never read; hiding it again is all there is to undo.
    if ($Before['hidden']) { Set-WinPkgsPowerSettingVisibility -Properties $Properties -Hidden $true; return }
    Write-WinPkgsPowerSetting -Scheme $scheme -Properties $Properties -Ac $Before['ac'] -Dc $Before['dc']
}

function Format-WinPkgsPowerSettingChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $parts = @()
    $ac = if ($Current['hidden']) { 'hidden' } else { Format-WinPkgsPowerValue $Current['ac'] }
    $dc = if ($Current['hidden']) { 'hidden' } else { Format-WinPkgsPowerValue $Current['dc'] }
    if ($null -ne $Properties['ac']) { $parts += "AC $ac -> $(Format-WinPkgsPowerValue $Properties['ac'])" }
    if ($null -ne $Properties['dc']) { $parts += "battery $dc -> $(Format-WinPkgsPowerValue $Properties['dc'])" }
    return ($parts -join ', ')
}

Register-WinPkgsResource -Type 'winpkgs/powerSetting' `
    -Get 'Get-WinPkgsPowerSetting' -Test 'Test-WinPkgsPowerSetting' -Set 'Set-WinPkgsPowerSetting' `
    -Restore 'Restore-WinPkgsPowerSetting' -Describe 'Format-WinPkgsPowerSettingChange'

# --- winpkgs/hibernation -------------------------------------------------------

function Get-WinPkgsHibernationKey {
    if ($env:WINPKGS_POWER_KEY) { return $env:WINPKGS_POWER_KEY }
    return 'HKLM\SYSTEM\CurrentControlSet\Control\Power'
}

function Get-WinPkgsHibernation {
    param([hashtable]$Properties, [hashtable]$Context)
    # The flag is written when hibernation is toggled; absent means Windows'
    # default, which is on wherever the hardware supports it.
    $v = Get-WinPkgsRegistryValue -Properties @{ key = (Get-WinPkgsHibernationKey); name = 'HibernateEnabled' }
    $enabled = $null
    if ($v['exists']) { $enabled = ([int64]$v['value'] -ne 0) }
    return @{ exists = $true; enabled = $enabled }
}

function Test-WinPkgsHibernation {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if ($null -eq $Current['enabled']) { return $false }   # unknown: say so once, explicitly
    return ([bool]$Current['enabled'] -eq [bool]$Properties['enabled'])
}

function Set-WinPkgsHibernationState {
    param([bool]$Enabled)
    $word = if ($Enabled) { 'on' } else { 'off' }
    Invoke-WinPkgsPowercfg -Arguments @('/hibernate', $word) | Out-Null
}

function Set-WinPkgsHibernation {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    Set-WinPkgsHibernationState -Enabled ([bool]$Properties['enabled'])
}

function Restore-WinPkgsHibernation {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    # Absent before means the default, which is on.
    $was = $true
    if ($null -ne $Before['enabled']) { $was = [bool]$Before['enabled'] }
    Set-WinPkgsHibernationState -Enabled $was
}

function Format-WinPkgsHibernationChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $from = if ($null -eq $Current['enabled']) { 'default' } elseif ($Current['enabled']) { 'on' } else { 'off' }
    $to = if ($Properties['enabled']) { 'on' } else { 'off' }
    return "$from -> $to"
}

Register-WinPkgsResource -Type 'winpkgs/hibernation' `
    -Get 'Get-WinPkgsHibernation' -Test 'Test-WinPkgsHibernation' -Set 'Set-WinPkgsHibernation' `
    -Restore 'Restore-WinPkgsHibernation' -Describe 'Format-WinPkgsHibernationChange'
