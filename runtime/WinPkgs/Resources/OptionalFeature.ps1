<#
    winpkgs/optionalFeature - whether one Windows optional feature is enabled:
    Hyper-V, Windows Sandbox, the WSL and Virtual Machine Platform features.
    Machine scope.

    properties: name, enabled

    Read through Win32_OptionalFeature, which answers unelevated, so a plan
    stays a plan: Get-WindowsOptionalFeature refuses even a read without
    elevation. CIM knows enabled, disabled and absent; it does not tell a
    feature waiting on a restart apart from the state it is leaving. When the
    process is elevated -- the apply -- DISM is asked instead, and does. So in
    the window between an apply and the restart it asked for, an unelevated
    plan may still show the feature as one to change, and the elevated apply
    then finds it pending and changes nothing.

    Changed through Enable-/Disable-WindowsOptionalFeature -Online -NoRestart.
    Enabling brings the parents a feature depends on with it (-All): declaring
    a feature means wanting it to work. Whether the change needs a restart is
    known only afterwards; the resource records it, the apply reports it and
    leaves with 3010, and nothing here restarts anything.

    A feature winpkgs enabled is owned (`owned.features`) and disabled again
    when it leaves the configuration (prune); one that was already enabled is
    managed, never owned. `false` disables whatever the ownership, since
    writing it is an explicit ask, and forgets it. A feature this Windows does
    not have counts as disabled, and enabling one is an error naming it.

    WINPKGS_FEATURE_STATE names a file standing in for DISM (tests): one
    `name=state` per line, state being enabled | disabled | enablePending |
    disablePending; a name not listed is absent. WINPKGS_FEATURE_LOG records
    every enable and disable; WINPKGS_FEATURE_RESTART lists, comma-separated,
    the features whose change needs a restart.
#>

# --- what DISM, or its stand-in, says -----------------------------------------

function Read-WinPkgsFeatureStandIn {
    $states = @{}
    if (Test-Path -LiteralPath $env:WINPKGS_FEATURE_STATE) {
        foreach ($line in Get-Content -LiteralPath $env:WINPKGS_FEATURE_STATE) {
            if ($line -match '^\s*([^=#]+?)\s*=\s*(\S+)\s*$') { $states[$Matches[1]] = $Matches[2] }
        }
    }
    return $states
}

function Save-WinPkgsFeatureStandIn {
    param([hashtable]$States)
    $lines = @($States.Keys | Sort-Object | ForEach-Object { "$_=$($States[$_])" })
    Set-Content -LiteralPath $env:WINPKGS_FEATURE_STATE -Value $lines
}

function Write-WinPkgsFeatureLog {
    param([string]$Line)
    if ($env:WINPKGS_FEATURE_LOG) { Add-Content -LiteralPath $env:WINPKGS_FEATURE_LOG -Value $Line }
}

function ConvertFrom-WinPkgsDismFeatureState {
    # DISM's FeatureState, as the cmdlet names it, into the resource's words.
    param([string]$State)
    switch -Regex ($State) {
        '^Enabled$'                    { return 'enabled' }
        '^Disabled(WithPayloadRemoved)?$' { return 'disabled' }
        '^EnablePending$'              { return 'enablePending' }
        '^DisablePending$'             { return 'disablePending' }
        '^NotPresent$'                 { return 'absent' }
        default                        { return 'unknown' }
    }
}

function Get-WinPkgsFeatureState {
    <#
    .SYNOPSIS
        One feature's state: enabled | disabled | enablePending |
        disablePending | absent | unknown.
    #>
    param([Parameter(Mandatory)][string]$Name)

    if ($env:WINPKGS_FEATURE_STATE) {
        $states = Read-WinPkgsFeatureStandIn
        if ($states.ContainsKey($Name)) { return [string]$states[$Name] }
        return 'absent'
    }

    if (Test-WinPkgsElevated) {
        # DISM tells a pending change from the state it leaves; CIM does not.
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue
        if (-not $feature) { return 'absent' }
        return ConvertFrom-WinPkgsDismFeatureState -State ([string]$feature.State)
    }

    $filter = "Name='{0}'" -f $Name.Replace("'", "\'")
    $instance = Get-CimInstance -ClassName Win32_OptionalFeature -Filter $filter -ErrorAction Stop
    if (-not $instance) { return 'absent' }
    switch ([int]$instance.InstallState) {
        1 { return 'enabled' }
        2 { return 'disabled' }
        3 { return 'absent' }
        default { return 'unknown' }
    }
}

function Enable-WinPkgsFeature {
    # Returns whether the change needs a restart.
    param([Parameter(Mandatory)][string]$Name)
    Write-WinPkgsFeatureLog "enable $Name"
    if ($env:WINPKGS_FEATURE_STATE) {
        $states = Read-WinPkgsFeatureStandIn
        if (-not $states.ContainsKey($Name)) { throw "Feature name $Name is unknown." }
        $restart = $Name -in @(([string]$env:WINPKGS_FEATURE_RESTART) -split ',')
        $states[$Name] = if ($restart) { 'enablePending' } else { 'enabled' }
        Save-WinPkgsFeatureStandIn -States $states
        return $restart
    }
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart -ErrorAction Stop -WarningAction SilentlyContinue
    return [bool]$result.RestartNeeded
}

function Disable-WinPkgsFeature {
    param([Parameter(Mandatory)][string]$Name)
    Write-WinPkgsFeatureLog "disable $Name"
    if ($env:WINPKGS_FEATURE_STATE) {
        $states = Read-WinPkgsFeatureStandIn
        $restart = $Name -in @(([string]$env:WINPKGS_FEATURE_RESTART) -split ',')
        $states[$Name] = if ($restart) { 'disablePending' } else { 'disabled' }
        Save-WinPkgsFeatureStandIn -States $states
        return $restart
    }
    $result = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop -WarningAction SilentlyContinue
    return [bool]$result.RestartNeeded
}

# --- the resource -------------------------------------------------------------

function Get-WinPkgsOptionalFeature {
    param([hashtable]$Properties, [hashtable]$Context)
    $state = Get-WinPkgsFeatureState -Name ([string]$Properties['name'])
    return @{ exists = ($state -ne 'absent'); state = $state }
}

function Test-WinPkgsOptionalFeature {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $wanted = [bool]$Properties['enabled']
    switch ([string]$Current['state']) {
        'enabled'        { return $wanted }
        'enablePending'  { return $wanted }
        'disabled'       { return (-not $wanted) }
        'disablePending' { return (-not $wanted) }
        'absent'         { return (-not $wanted) }   # what is not there cannot be on
        default          { return $false }
    }
}

function Set-WinPkgsOptionalFeature {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $name = [string]$Properties['name']
    if ([bool]$Properties['enabled']) {
        if ($Current['state'] -eq 'absent') {
            throw "No optional feature named $name on this Windows. 'Get-WindowsOptionalFeature -Online' (elevated) lists them."
        }
        $restart = Enable-WinPkgsFeature -Name $name
        Add-WinPkgsOwned -Context $Context -Backend 'features' -Id $name
    } else {
        $restart = Disable-WinPkgsFeature -Name $name
        Remove-WinPkgsOwned -Context $Context -Backend 'features' -Id $name
    }
    if ($restart) { Set-WinPkgsRestartRequired -Because "Feature $name" }
}

function Remove-WinPkgsOptionalFeature {
    # Prune: winpkgs enabled it and the configuration no longer names it.
    param([hashtable]$Properties, [hashtable]$Context)
    $name = [string]$Properties['name']
    $state = Get-WinPkgsFeatureState -Name $name
    if ($state -in @('enabled', 'enablePending')) {
        if (Disable-WinPkgsFeature -Name $name) { Set-WinPkgsRestartRequired -Because "Feature $name" }
    }
    Remove-WinPkgsOwned -Context $Context -Backend 'features' -Id $name
}

function Format-WinPkgsOptionalFeatureChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $words = @{ enabled = 'enabled'; disabled = 'disabled'; enablePending = 'enabled after a restart'
                disablePending = 'disabled after a restart'; absent = 'not present'; unknown = 'unknown' }
    $from = $words[[string]$Current['state']]
    $to = if ([bool]$Properties['enabled']) { 'enabled' } else { 'disabled' }
    return "$from -> $to"
}

Register-WinPkgsResource -Type 'winpkgs/optionalFeature' `
    -Get 'Get-WinPkgsOptionalFeature' -Test 'Test-WinPkgsOptionalFeature' -Set 'Set-WinPkgsOptionalFeature' `
    -Remove 'Remove-WinPkgsOptionalFeature' -Describe 'Format-WinPkgsOptionalFeatureChange'
