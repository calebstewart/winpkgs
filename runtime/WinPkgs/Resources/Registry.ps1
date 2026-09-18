<#
    winpkgs/registry - one named value under one key.

    properties: key, name, type (DWord|QWord|String|ExpandString|MultiString|Binary|Absent),
                value, restartExplorer

    An empty `name` is the key's unnamed default value.
#>

$script:RegistryHives = @{
    HKCU = 'HKEY_CURRENT_USER'
    HKLM = 'HKEY_LOCAL_MACHINE'
    HKU  = 'HKEY_USERS'
    HKCR = 'HKEY_CLASSES_ROOT'
    HKCC = 'HKEY_CURRENT_CONFIG'
}

# Base keys for the one thing the provider cannot do: delete a key's unnamed
# default value.
$script:RegistryBaseKeys = @{
    HKEY_CURRENT_USER   = [Microsoft.Win32.Registry]::CurrentUser
    HKEY_LOCAL_MACHINE  = [Microsoft.Win32.Registry]::LocalMachine
    HKEY_USERS          = [Microsoft.Win32.Registry]::Users
    HKEY_CLASSES_ROOT   = [Microsoft.Win32.Registry]::ClassesRoot
    HKEY_CURRENT_CONFIG = [Microsoft.Win32.Registry]::CurrentConfig
}

function Split-WinPkgsRegistryKey {
    # The full hive name and the subkey path under it.
    param([Parameter(Mandatory)][string]$Key)
    $parts = $Key -split '\\', 2
    $hive = $parts[0].ToUpperInvariant()
    if ($script:RegistryHives.ContainsKey($hive)) { $hive = $script:RegistryHives[$hive] }
    $sub = ''
    if ($parts.Count -gt 1) { $sub = $parts[1] }
    return @{ hive = $hive; sub = $sub }
}

function ConvertTo-WinPkgsRegistryPath {
    param([Parameter(Mandatory)][string]$Key)
    $k = Split-WinPkgsRegistryKey -Key $Key
    if ($k['sub']) { return "Registry::$($k['hive'])\$($k['sub'])" }
    return "Registry::$($k['hive'])"
}

# --- key ownership ------------------------------------------------------------------
#
# Writing a value creates the keys on the way to it, and `winpkgs/registryKey`
# can be asked to delete a key outright. So the ledger records which keys
# winpkgs brought into existence (`owned.registryKeys`), and a delete of a key
# that is not among them is refused: deleting a key winpkgs created puts the
# machine back as it was, deleting one that was already there destroys somebody
# else's data, and a key takes its whole subtree with it either way.
#
# Ownership is ledger state, not generation state, so it outlives the
# configuration that created the key: a key created in generation 12 is still
# winpkgs' when generation 11 is applied again.
#
# What records is the declared registry surface -- `winpkgs/registry` and
# `winpkgs/registryKey`, the two resources `windows.registry` and
# `windows.registryKeys` produce -- because that surface is the only one
# `windows.registryKeys` can be pointed at. The modelled resources that reach
# the registry through the same writer (the pointer scheme, the wallpaper, the
# time service, an offline install's Add/Remove Programs key) pass no context
# and record nothing: they write into keys Windows itself already has, and the
# one that does create a key keeps its own book (`arp`). So the refusal claims
# only what the ledger knows -- no record of creating it -- rather than that
# nothing in winpkgs ever did.

function ConvertTo-WinPkgsRegistryKeyId {
    # The canonical spelling of a key path, as the ledger records it: the full
    # hive name, no empty or repeated separators. Key names are
    # case-insensitive, so the ledger keeps a path as it was written and
    # matching folds case.
    param([Parameter(Mandatory)][string]$Key)
    $k = Split-WinPkgsRegistryKey -Key $Key
    $sub = (@($k['sub'] -split '\\' | Where-Object { $_ -ne '' })) -join '\'
    if ($sub) { return "$($k['hive'])\$sub" }
    return $k['hive']
}

function Get-WinPkgsRegistryKeyChain {
    # A key and every ancestor of it under its hive, outermost first: what
    # creating that key may have to create to reach it. The hive itself is not
    # in the chain; nothing creates or deletes a hive, so a bare hive has no
    # chain at all -- which is why this returns its list to the pipeline rather
    # than wrapping it: `, @()` is a list of one empty list, not an empty one.
    param([Parameter(Mandatory)][string]$Key)
    $k = Split-WinPkgsRegistryKey -Key $Key
    $chain = @()
    $path = $k['hive']
    foreach ($part in @($k['sub'] -split '\\' | Where-Object { $_ -ne '' })) {
        $path = "$path\$part"
        $chain += $path
    }
    return $chain
}

function Get-WinPkgsMissingRegistryKeys {
    # Which of a key's chain are not there yet -- exactly what creating it
    # brings into existence, and so exactly what winpkgs then owns. Asked
    # before the write, since afterwards there is no telling.
    param([Parameter(Mandatory)][string]$Key)
    $missing = @()
    foreach ($k in @(Get-WinPkgsRegistryKeyChain -Key $Key)) {
        if (Test-Path -LiteralPath (ConvertTo-WinPkgsRegistryPath -Key $k)) { continue }
        $missing += $k
    }
    return $missing
}

function Get-WinPkgsRegistryLedger {
    # The live ledger during an apply, a fresh read during a plan -- how the
    # task resource reads its own ownership.
    param([hashtable]$Context)
    if ($Context -and $Context['State']) { return $Context['State'] }
    $kind = if ($Context -and $Context['Kind']) { $Context['Kind'] } else { 'system' }
    return Read-WinPkgsState -Kind $kind
}

function Test-WinPkgsRegistryKeyOwned {
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Context)
    $id = ConvertTo-WinPkgsRegistryKeyId -Key $Key
    foreach ($owned in @((Get-WinPkgsRegistryLedger -Context $Context)['owned']['registryKeys'])) {
        if ([string]$owned -ieq $id) { return $true }
    }
    return $false
}

function Add-WinPkgsOwnedRegistryKey {
    # Nothing to record is the ordinary case -- a write into a key that was
    # already there -- so an empty list, or none, is not an error.
    param([hashtable]$Context, [string[]]$Keys = @())
    foreach ($key in $Keys) {
        if ([string]::IsNullOrEmpty($key)) { continue }
        Add-WinPkgsOwned -Context $Context -Backend 'registryKeys' -Id (ConvertTo-WinPkgsRegistryKeyId -Key $key)
    }
}

function Remove-WinPkgsOwnedRegistryKey {
    # A deleted key takes its subkeys with it, so the ledger forgets the key
    # and everything recorded beneath it. An entry left behind would let a
    # later apply delete a key of the same path that somebody else created.
    param([hashtable]$Context, [Parameter(Mandatory)][string]$Key)
    if (-not $Context -or -not $Context['State']) { return }
    $id = ConvertTo-WinPkgsRegistryKeyId -Key $Key
    $under = "$id\"
    $Context['State']['owned']['registryKeys'] = @(
        $Context['State']['owned']['registryKeys'] | Where-Object {
            $owned = [string]$_
            -not ($owned -ieq $id -or $owned.StartsWith($under, [System.StringComparison]::OrdinalIgnoreCase))
        }
    )
}

function Resolve-WinPkgsValueName {
    # A key's unnamed default value is '' to the registry API -- what
    # GetValueNames() reports, and what the document carries -- but the provider
    # cmdlets reject '' and spell it '(default)'.
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return '(default)' }
    return $Name
}

function Remove-WinPkgsRegistryValue {
    # Remove-ItemProperty cannot delete a default value under either spelling:
    # '' fails parameter binding, and '(default)' reports the property missing.
    # Only the .NET API can, so that one case takes the long way round.
    param([Parameter(Mandatory)][string]$Key, [string]$Name)
    if (-not [string]::IsNullOrEmpty($Name)) {
        Remove-ItemProperty -LiteralPath (ConvertTo-WinPkgsRegistryPath -Key $Key) -Name $Name -Force
        return
    }
    $k = Split-WinPkgsRegistryKey -Key $Key
    $base = $script:RegistryBaseKeys[$k['hive']]
    if (-not $base) { throw "Unknown registry hive: $($k['hive'])" }
    $sub = $base.OpenSubKey($k['sub'], $true)
    if (-not $sub) { return }
    try { $sub.DeleteValue('', $false) } finally { $sub.Close() }
}

function ConvertFrom-WinPkgsRegistryValue {
    # Normalise what RegistryKey.GetValue returns into JSON-friendly shapes.
    param([string]$Kind, $Value)
    switch ($Kind) {
        # GetValue hands back a signed Int32; reinterpret as unsigned. The L suffix
        # matters: a bare 0xFFFFFFFF literal is Int32 -1 in PowerShell.
        'DWord'       { return ([int64]$Value -band 0xFFFFFFFFL) }
        'QWord'       { return [int64]$Value }
        'MultiString' { return [string[]]@($Value) }
        'Binary'      { return [int[]]@($Value | ForEach-Object { [int]$_ }) }
        default       { return [string]$Value }
    }
}

function ConvertTo-WinPkgsRegistryValue {
    # The inverse: JSON shapes into what Set-ItemProperty -Type expects.
    param([string]$Kind, $Value)
    switch ($Kind) {
        'DWord' {
            $v = [int64]$Value
            if ($v -gt 0x7FFFFFFF) { return [int32]($v - 0x100000000) }
            return [int32]$v
        }
        'QWord'       { return [int64]$Value }
        'MultiString' { return [string[]]@($Value) }
        'Binary'      { return [byte[]]@($Value | ForEach-Object { [byte]$_ }) }
        default       { return [string]$Value }
    }
}

function Compare-WinPkgsRegistryValue {
    param([string]$Kind, $Expected, $Actual)
    switch ($Kind) {
        { $_ -in 'DWord', 'QWord' } { return ([int64]$Expected -eq [int64]$Actual) }
        { $_ -in 'String', 'ExpandString' } { return ([string]$Expected -ceq [string]$Actual) }
        { $_ -in 'MultiString', 'Binary' } {
            $e = @($Expected); $a = @($Actual)
            if ($e.Count -ne $a.Count) { return $false }
            for ($i = 0; $i -lt $e.Count; $i++) {
                if ("$($e[$i])" -cne "$($a[$i])") { return $false }
            }
            return $true
        }
    }
    return $false
}

function Test-WinPkgsUcpdRunning {
    <#
    .SYNOPSIS
        Is the User Choice Protection Driver loaded?

    .DESCRIPTION
        UCPD is a filter driver that refuses writes to the default-browser and
        file-association values and to the taskbar's Widgets button, below the
        permission system and regardless of who owns the key. Asked only when a
        write has already been refused, so its cost never falls on a good apply.
    #>
    $svc = Get-Service -Name UCPD -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

function New-WinPkgsAccessDeniedMessage {
    # What "Attempted to perform an unauthorized operation" means for a registry
    # value, said in terms of the thing that can be done about it.
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Name,
        [Parameter(Mandatory)][string]$Reason,
        [bool]$UcpdRunning
    )
    $value = if ([string]::IsNullOrEmpty($Name)) { '(default)' } else { $Name }
    if ($UcpdRunning) {
        return @(
            "Windows refused the write to ${Key}\${value}: $Reason"
            'The User Choice Protection Driver (UCPD) is running. It refuses writes to the'
            'default-browser and file-association values and to the taskbar Widgets button,'
            "whatever the key's permissions say, so this cannot succeed while it is loaded."
            'Set `windows.userChoiceProtection.enable = false` in the system configuration,'
            'apply that, and restart -- the driver loads at boot.'
        ) -join [Environment]::NewLine
    }
    return "Windows refused the write to ${Key}\${value}: $Reason"
}

function Write-WinPkgsRegistryValue {
    param([string]$Key, [string]$Name, [string]$Kind, $Value, [hashtable]$Context)
    $path = ConvertTo-WinPkgsRegistryPath -Key $Key
    if (-not (Test-Path -LiteralPath $path)) {
        # -Force creates the ancestors on the way as well, and winpkgs owns
        # every key it had to create -- which only the state before the write
        # can still tell.
        $created = @(Get-WinPkgsMissingRegistryKeys -Key $Key)
        New-Item -Path $path -Force | Out-Null
        Add-WinPkgsOwnedRegistryKey -Context $Context -Keys $created
    }
    $item = Get-Item -LiteralPath $path
    if (@($item.GetValueNames()) -contains $Name -and $item.GetValueKind($Name).ToString() -ne $Kind) {
        # Set-ItemProperty will not change the kind of an existing value.
        Remove-WinPkgsRegistryValue -Key $Key -Name $Name
    }
    $typed = ConvertTo-WinPkgsRegistryValue -Kind $Kind -Value $Value
    try {
        Set-ItemProperty -LiteralPath $path -Name (Resolve-WinPkgsValueName $Name) -Value $typed -Type $Kind -ErrorAction Stop
    } catch [System.UnauthorizedAccessException], [System.Security.SecurityException] {
        # A denial here is not always about permissions, and the difference
        # matters: one is fixable by elevating, the other is not fixable at all
        # until a driver is turned off.
        throw (New-WinPkgsAccessDeniedMessage -Key $Key -Name $Name `
                -Reason $_.Exception.Message -UcpdRunning (Test-WinPkgsUcpdRunning))
    }
}

function Get-WinPkgsRegistryValue {
    param([hashtable]$Properties, [hashtable]$Context)
    $path = ConvertTo-WinPkgsRegistryPath -Key $Properties['key']
    $name = [string]$Properties['name']

    if (-not (Test-Path -LiteralPath $path)) { return @{ exists = $false; keyExists = $false } }
    $key = Get-Item -LiteralPath $path
    if (@($key.GetValueNames()) -notcontains $name) { return @{ exists = $false; keyExists = $true } }

    $kind = $key.GetValueKind($name).ToString()
    $raw = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return @{
        exists    = $true
        keyExists = $true
        type      = $kind
        value     = ConvertFrom-WinPkgsRegistryValue -Kind $kind -Value $raw
    }
}

function Test-WinPkgsRegistryValue {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if ($Properties['type'] -eq 'Absent') { return (-not $Current['exists']) }
    if (-not $Current['exists']) { return $false }
    if ($Current['type'] -ne $Properties['type']) { return $false }
    return Compare-WinPkgsRegistryValue -Kind $Properties['type'] -Expected $Properties['value'] -Actual $Current['value']
}

function Set-WinPkgsRegistryValue {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $key = [string]$Properties['key']
    $name = [string]$Properties['name']

    if ($Properties['type'] -eq 'Absent') {
        if ($Current['exists']) { Remove-WinPkgsRegistryValue -Key $key -Name $name }
        return
    }
    Write-WinPkgsRegistryValue -Key $key -Name $name -Kind $Properties['type'] -Value $Properties['value'] -Context $Context
}

function Format-WinPkgsRegistryChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $show = {
        param($kind, $value)
        if ($kind -eq 'Absent' -or $null -eq $kind) { return 'absent' }
        if ($value -is [array]) { return "$kind [$($value -join ', ')]" }
        return "$kind $value"
    }
    $from = if ($Current['exists']) { & $show $Current['type'] $Current['value'] } else { 'absent' }
    $to = & $show $Properties['type'] $Properties['value']
    if ($from -ceq $to) { return $to }
    return "$from -> $to"
}

Register-WinPkgsResource -Type 'winpkgs/registry' `
    -Get 'Get-WinPkgsRegistryValue' `
    -Test 'Test-WinPkgsRegistryValue' `
    -Set 'Set-WinPkgsRegistryValue' `
    -Describe 'Format-WinPkgsRegistryChange'
