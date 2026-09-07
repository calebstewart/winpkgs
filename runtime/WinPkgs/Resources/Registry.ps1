<#
    winpkgs/registry - one named value under one key.

    properties: key, name, type (DWord|QWord|String|ExpandString|MultiString|Binary|Absent),
                value, restartExplorer
#>

$script:RegistryHives = @{
    HKCU = 'HKEY_CURRENT_USER'
    HKLM = 'HKEY_LOCAL_MACHINE'
    HKU  = 'HKEY_USERS'
    HKCR = 'HKEY_CLASSES_ROOT'
    HKCC = 'HKEY_CURRENT_CONFIG'
}

function ConvertTo-WinPkgsRegistryPath {
    param([Parameter(Mandatory)][string]$Key)
    $parts = $Key -split '\\', 2
    $hive = $parts[0].ToUpperInvariant()
    if ($script:RegistryHives.ContainsKey($hive)) { $hive = $script:RegistryHives[$hive] }
    if ($parts.Count -gt 1 -and $parts[1]) { return "Registry::$hive\$($parts[1])" }
    return "Registry::$hive"
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

function Write-WinPkgsRegistryValue {
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $key = Get-Item -LiteralPath $Path
    if (@($key.GetValueNames()) -contains $Name -and $key.GetValueKind($Name).ToString() -ne $Kind) {
        # Set-ItemProperty will not change the kind of an existing value.
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force
    }
    $typed = ConvertTo-WinPkgsRegistryValue -Kind $Kind -Value $Value
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $typed -Type $Kind
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
    $path = ConvertTo-WinPkgsRegistryPath -Key $Properties['key']
    $name = [string]$Properties['name']

    if ($Properties['type'] -eq 'Absent') {
        if ($Current['exists']) { Remove-ItemProperty -LiteralPath $path -Name $name -Force }
        return
    }
    Write-WinPkgsRegistryValue -Path $path -Name $name -Kind $Properties['type'] -Value $Properties['value']
}

function Restore-WinPkgsRegistryValue {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $path = ConvertTo-WinPkgsRegistryPath -Key $Properties['key']
    $name = [string]$Properties['name']

    if ($Before['exists']) {
        Write-WinPkgsRegistryValue -Path $path -Name $name -Kind $Before['type'] -Value $Before['value']
        return
    }
    # Value did not exist before. Remove it; leave the key (deleting keys we did
    # not create could take siblings with them).
    if (Test-Path -LiteralPath $path) {
        $key = Get-Item -LiteralPath $path
        if (@($key.GetValueNames()) -contains $name) {
            Remove-ItemProperty -LiteralPath $path -Name $name -Force
        }
    }
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
    -Restore 'Restore-WinPkgsRegistryValue' `
    -Describe 'Format-WinPkgsRegistryChange'
