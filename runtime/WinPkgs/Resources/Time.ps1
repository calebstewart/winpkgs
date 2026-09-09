<#
    Time. Two resource types, both machine scope:

      winpkgs/timeZone  the system time zone   properties: id (a Windows time-zone id)
      winpkgs/timeSync  the w32time NTP client properties: enabled, servers, pollInterval,
                                               maxCorrection, resync (null leaves a setting alone)

    tzutil is the only honest writer of the zone: `TimeZoneKeyName` is one of
    half a dozen values that describe a zone, and the bias and DST rules are
    recomputed from the id rather than stored independently, so writing the key
    alone leaves the running clock on the old offset.

    w32time is the reverse -- there is no command for most of its settings, so
    they are written to the registry -- but it reads them once, at start and on
    `w32tm /config /update`. Hence one resource over three keys: the settings
    take effect together or not at all, and a half-applied peer list with a
    stale poll interval is not a state worth being able to reach.

    WINPKGS_TZUTIL and WINPKGS_W32TM name scripts to run instead of the real
    tools; WINPKGS_W32TIME_KEY redirects the settings; WINPKGS_W32TIME_SERVICE_STATE
    names a file standing in for the service control manager (tests).
#>

# Both tools report failure by exit code, and their stderr is worth quoting
# when they do; Invoke-WinPkgsExternal (Private/External.ps1) keeps the host
# from turning either into an exception first.
function Invoke-WinPkgsTzutil {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = if ($env:WINPKGS_TZUTIL) { $env:WINPKGS_TZUTIL } else { 'tzutil.exe' }
    $r = Invoke-WinPkgsExternal -Command $exe -Arguments $Arguments
    if ($r['failed']) { throw "tzutil $($Arguments -join ' ') failed: $($r['text'])" }
    return $r['lines']
}

function Invoke-WinPkgsW32tm {
    # $Tolerate is for /resync, which fails for reasons that are not this
    # resource's fault -- no network yet, the service still settling.
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Tolerate)
    $exe = if ($env:WINPKGS_W32TM) { $env:WINPKGS_W32TM } else { 'w32tm.exe' }
    $r = Invoke-WinPkgsExternal -Command $exe -Arguments $Arguments
    if ($r['failed']) {
        if ($Tolerate) {
            Write-Warning "w32tm $($Arguments -join ' ') failed: $($r['text']). The configuration is applied; the clock corrects itself at the next poll."
            return @()
        }
        throw "w32tm $($Arguments -join ' ') failed: $($r['text'])"
    }
    return $r['lines']
}

# --- winpkgs/timeZone ----------------------------------------------------------

function Get-WinPkgsTimeZone {
    param([hashtable]$Properties, [hashtable]$Context)
    $lines = @(Invoke-WinPkgsTzutil -Arguments @('/g') | Where-Object { $_ -and $_.Trim() })
    if ($lines.Count -lt 1) { throw 'tzutil /g returned no time zone' }
    return @{ exists = $true; id = $lines[0].Trim() }
}

function Test-WinPkgsTimeZone {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    return ([string]$Current['id'] -ieq [string]$Properties['id'])
}

function Set-WinPkgsTimeZone {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    try {
        Invoke-WinPkgsTzutil -Arguments @('/s', [string]$Properties['id']) | Out-Null
    } catch {
        throw "$($_.Exception.Message). 'tzutil /l' lists the ids this machine knows."
    }
}

function Restore-WinPkgsTimeZone {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    if ($Before['id']) { Invoke-WinPkgsTzutil -Arguments @('/s', [string]$Before['id']) | Out-Null }
}

function Format-WinPkgsTimeZoneChange {
    param([hashtable]$Properties, [hashtable]$Current)
    return "$($Current['id']) -> $($Properties['id'])"
}

Register-WinPkgsResource -Type 'winpkgs/timeZone' `
    -Get 'Get-WinPkgsTimeZone' -Test 'Test-WinPkgsTimeZone' -Set 'Set-WinPkgsTimeZone' `
    -Restore 'Restore-WinPkgsTimeZone' -Describe 'Format-WinPkgsTimeZoneChange'

# --- winpkgs/timeSync ----------------------------------------------------------

function Get-WinPkgsW32TimeKey {
    if ($env:WINPKGS_W32TIME_KEY) { return $env:WINPKGS_W32TIME_KEY }
    return 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time'
}

# Where each setting lives, relative to that key.
function Get-WinPkgsW32TimeLayout {
    $root = Get-WinPkgsW32TimeKey
    return @{
        servers      = @{ key = "$root\Parameters"; name = 'NtpServer'; kind = 'String' }
        type         = @{ key = "$root\Parameters"; name = 'Type'; kind = 'String' }
        enabled      = @{ key = "$root\TimeProviders\NtpClient"; name = 'Enabled'; kind = 'DWord' }
        pollInterval = @{ key = "$root\TimeProviders\NtpClient"; name = 'SpecialPollInterval'; kind = 'DWord' }
        maxPos       = @{ key = "$root\Config"; name = 'MaxPosPhaseCorrection'; kind = 'DWord' }
        maxNeg       = @{ key = "$root\Config"; name = 'MaxNegPhaseCorrection'; kind = 'DWord' }
    }
}

function Read-WinPkgsW32TimeValue {
    param([hashtable]$Where)
    $v = Get-WinPkgsRegistryValue -Properties @{ key = $Where['key']; name = $Where['name'] }
    if (-not $v['exists']) { return $null }
    return $v['value']
}

function Write-WinPkgsW32TimeValue {
    # $null means "not present": the setting is removed, so w32time falls back
    # to its built-in default rather than to a value we invented.
    param([hashtable]$Where, $Value)
    if ($null -eq $Value) {
        $cur = Get-WinPkgsRegistryValue -Properties @{ key = $Where['key']; name = $Where['name'] }
        if ($cur['exists']) { Remove-WinPkgsRegistryValue -Key $Where['key'] -Name $Where['name'] }
        return
    }
    Write-WinPkgsRegistryValue -Key $Where['key'] -Name $Where['name'] -Kind $Where['kind'] -Value $Value
}

# --- the service ---

function Get-WinPkgsTimeServiceState {
    if ($env:WINPKGS_W32TIME_SERVICE_STATE) {
        $state = @{ startType = 'Manual'; running = $false }
        if (Test-Path -LiteralPath $env:WINPKGS_W32TIME_SERVICE_STATE) {
            foreach ($line in Get-Content -LiteralPath $env:WINPKGS_W32TIME_SERVICE_STATE) {
                if ($line -match '^(.*?)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
            }
        }
        return @{ startType = [string]$state['startType']; running = ([string]$state['running'] -eq 'True') }
    }
    $svc = Get-Service -Name 'w32time' -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ startType = $null; running = $null } }
    return @{ startType = [string]$svc.StartType; running = ($svc.Status -eq 'Running') }
}

function Set-WinPkgsTimeServiceState {
    param([string]$StartType, [nullable[bool]]$Running)
    if ($env:WINPKGS_W32TIME_SERVICE_STATE) {
        $state = Get-WinPkgsTimeServiceState
        if ($StartType) { $state['startType'] = $StartType }
        if ($null -ne $Running) { $state['running'] = $Running }
        @("startType=$($state['startType'])", "running=$($state['running'])") |
            Set-Content -LiteralPath $env:WINPKGS_W32TIME_SERVICE_STATE
        return
    }
    if (-not (Get-Service -Name 'w32time' -ErrorAction SilentlyContinue)) { return }
    if ($StartType) { Set-Service -Name 'w32time' -StartupType $StartType }
    if ($Running -eq $true) { Start-Service -Name 'w32time' -ErrorAction SilentlyContinue }
    elseif ($Running -eq $false) { Stop-Service -Name 'w32time' -Force -ErrorAction SilentlyContinue }
}

# --- get / test / set ---

function Get-WinPkgsTimeSync {
    param([hashtable]$Properties, [hashtable]$Context)
    $l = Get-WinPkgsW32TimeLayout
    $enabled = Read-WinPkgsW32TimeValue -Where $l['enabled']
    $svc = Get-WinPkgsTimeServiceState
    return @{
        exists       = $true
        servers      = Read-WinPkgsW32TimeValue -Where $l['servers']
        type         = Read-WinPkgsW32TimeValue -Where $l['type']
        enabled      = $(if ($null -eq $enabled) { $null } else { [int64]$enabled -ne 0 })
        pollInterval = Read-WinPkgsW32TimeValue -Where $l['pollInterval']
        maxPos       = Read-WinPkgsW32TimeValue -Where $l['maxPos']
        maxNeg       = Read-WinPkgsW32TimeValue -Where $l['maxNeg']
        startType    = $svc['startType']
        running      = $svc['running']
    }
}

function Test-WinPkgsTimeSync {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)

    if ($null -ne $Properties['servers'] -and [string]$Current['servers'] -ine [string]$Properties['servers']) { return $false }
    if ($null -ne $Properties['pollInterval'] -and
        ($null -eq $Current['pollInterval'] -or [int64]$Current['pollInterval'] -ne [int64]$Properties['pollInterval'])) { return $false }
    if ($null -ne $Properties['maxCorrection']) {
        foreach ($side in 'maxPos', 'maxNeg') {
            if ($null -eq $Current[$side] -or [int64]$Current[$side] -ne [int64]$Properties['maxCorrection']) { return $false }
        }
    }
    if ($null -ne $Properties['enabled']) {
        $want = [bool]$Properties['enabled']
        if ($null -eq $Current['enabled'] -or [bool]$Current['enabled'] -ne $want) { return $false }
        if ([string]$Current['type'] -ine $(if ($want) { 'NTP' } else { 'NoSync' })) { return $false }
        # Enabled but never started is enabled in name only.
        if ($want -and $null -ne $Current['startType']) {
            if ([string]$Current['startType'] -ine 'Automatic' -or -not $Current['running']) { return $false }
        }
    }
    return $true
}

function Set-WinPkgsTimeSync {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $l = Get-WinPkgsW32TimeLayout

    if ($null -ne $Properties['servers']) { Write-WinPkgsW32TimeValue -Where $l['servers'] -Value $Properties['servers'] }
    if ($null -ne $Properties['pollInterval']) { Write-WinPkgsW32TimeValue -Where $l['pollInterval'] -Value $Properties['pollInterval'] }
    if ($null -ne $Properties['maxCorrection']) {
        Write-WinPkgsW32TimeValue -Where $l['maxPos'] -Value $Properties['maxCorrection']
        Write-WinPkgsW32TimeValue -Where $l['maxNeg'] -Value $Properties['maxCorrection']
    }

    $enabled = $Properties['enabled']
    if ($null -ne $enabled) {
        Write-WinPkgsW32TimeValue -Where $l['enabled'] -Value $(if ($enabled) { 1 } else { 0 })
        Write-WinPkgsW32TimeValue -Where $l['type'] -Value $(if ($enabled) { 'NTP' } else { 'NoSync' })
        if ($enabled) { Set-WinPkgsTimeServiceState -StartType 'Automatic' -Running $true }
    }

    # Nothing above is read until w32time is told to re-read it.
    Invoke-WinPkgsW32tm -Arguments @('/config', '/update') | Out-Null

    if ($Properties['resync'] -and $enabled -ne $false) {
        Invoke-WinPkgsW32tm -Arguments @('/resync', '/force') -Tolerate | Out-Null
    }
}

function Restore-WinPkgsTimeSync {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $l = Get-WinPkgsW32TimeLayout

    foreach ($pair in @(
            @{ where = $l['servers']; was = $Before['servers'] },
            @{ where = $l['type']; was = $Before['type'] },
            @{ where = $l['pollInterval']; was = $Before['pollInterval'] },
            @{ where = $l['maxPos']; was = $Before['maxPos'] },
            @{ where = $l['maxNeg']; was = $Before['maxNeg'] }
        )) {
        Write-WinPkgsW32TimeValue -Where $pair['where'] -Value $pair['was']
    }
    $wasEnabled = $Before['enabled']
    Write-WinPkgsW32TimeValue -Where $l['enabled'] -Value $(if ($null -eq $wasEnabled) { $null } elseif ($wasEnabled) { 1 } else { 0 })

    if ($Before['startType']) {
        Set-WinPkgsTimeServiceState -StartType ([string]$Before['startType']) -Running ([nullable[bool]]$Before['running'])
    }
    Invoke-WinPkgsW32tm -Arguments @('/config', '/update') | Out-Null
}

function Format-WinPkgsTimeSyncChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $show = { param($v) if ($null -eq $v) { 'unset' } else { [string]$v } }
    # A setting already at the wanted value is not part of the change, even
    # though it is part of what this resource covers: one setting out of six
    # should not print the other five as "3600s -> 3600s".
    $differs = { param($was, $want) ($null -eq $was) -or ([int64]$was -ne [int64]$want) }
    $parts = @()
    if ($null -ne $Properties['enabled'] -and
        ($null -eq $Current['enabled'] -or [bool]$Current['enabled'] -ne [bool]$Properties['enabled'])) {
        $from = if ($null -eq $Current['enabled']) { 'unset' } elseif ($Current['enabled']) { 'on' } else { 'off' }
        $parts += "sync $from -> $(if ($Properties['enabled']) { 'on' } else { 'off' })"
    }
    if ($null -ne $Properties['servers'] -and [string]$Current['servers'] -ine [string]$Properties['servers']) {
        $parts += "peers $(& $show $Current['servers']) -> $($Properties['servers'])"
    }
    if ($null -ne $Properties['pollInterval'] -and (& $differs $Current['pollInterval'] $Properties['pollInterval'])) {
        $parts += "poll $(& $show $Current['pollInterval'])s -> $($Properties['pollInterval'])s"
    }
    if ($null -ne $Properties['maxCorrection'] -and
        ((& $differs $Current['maxPos'] $Properties['maxCorrection']) -or (& $differs $Current['maxNeg'] $Properties['maxCorrection']))) {
        $parts += "max correction $(& $show $Current['maxPos'])s -> $($Properties['maxCorrection'])s"
    }
    if ($Properties['enabled'] -and $Current['startType'] -and [string]$Current['startType'] -ine 'Automatic') {
        $parts += "service $($Current['startType']) -> Automatic"
    }
    if ($parts.Count -eq 0) { return 'reload' }
    return ($parts -join ', ')
}

Register-WinPkgsResource -Type 'winpkgs/timeSync' `
    -Get 'Get-WinPkgsTimeSync' -Test 'Test-WinPkgsTimeSync' -Set 'Set-WinPkgsTimeSync' `
    -Restore 'Restore-WinPkgsTimeSync' -Describe 'Format-WinPkgsTimeSyncChange'
