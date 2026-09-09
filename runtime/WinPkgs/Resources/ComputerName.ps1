<#
    winpkgs/computerName - the machine's name. Machine scope.

    properties: name

    Windows keeps two: the active name, and the one that becomes active at
    the next restart. Rename-Computer writes the second (and the TCP/IP host
    name with it); the resource is in state as soon as the pending name is
    the declared one, since the restart is the user's to choose. Names are
    compared without case: Windows stores what it was given and matches
    without it.

    WINPKGS_COMPUTERNAME_KEY redirects the key and skips the real rename (tests).
#>

function Get-WinPkgsComputerNameKeys {
    if ($env:WINPKGS_COMPUTERNAME_KEY) { return @{ base = $env:WINPKGS_COMPUTERNAME_KEY; live = $false } }
    return @{ base = 'HKLM\SYSTEM\CurrentControlSet\Control\ComputerName'; live = $true }
}

function Get-WinPkgsComputerNameValue {
    param([string]$Base, [string]$Sub)
    $v = Get-WinPkgsRegistryValue -Properties @{ key = "$Base\$Sub"; name = 'ComputerName' }
    if ($v['exists']) { return [string]$v['value'] }
    return $null
}

function Get-WinPkgsComputerName {
    param([hashtable]$Properties, [hashtable]$Context)
    $k = Get-WinPkgsComputerNameKeys
    return @{
        exists  = $true
        active  = Get-WinPkgsComputerNameValue -Base $k.base -Sub 'ActiveComputerName'
        pending = Get-WinPkgsComputerNameValue -Base $k.base -Sub 'ComputerName'
    }
}

function Test-WinPkgsComputerName {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    return ([string]$Current['pending'] -ieq [string]$Properties['name'])
}

function Rename-WinPkgsComputer {
    param([string]$Name)
    $k = Get-WinPkgsComputerNameKeys
    if ($k.live) {
        Rename-Computer -NewName $Name -Force -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        return
    }
    Write-WinPkgsRegistryValue -Key "$($k.base)\ComputerName" -Name 'ComputerName' -Kind String -Value $Name
}

function Set-WinPkgsComputerName {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    Rename-WinPkgsComputer -Name ([string]$Properties['name'])
}

function Restore-WinPkgsComputerName {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    if ($Before['pending']) { Rename-WinPkgsComputer -Name ([string]$Before['pending']) }
}

function Format-WinPkgsComputerNameChange {
    param([hashtable]$Properties, [hashtable]$Current)
    return "$($Current['pending']) -> $($Properties['name']) (after a restart)"
}

Register-WinPkgsResource -Type 'winpkgs/computerName' `
    -Get 'Get-WinPkgsComputerName' -Test 'Test-WinPkgsComputerName' -Set 'Set-WinPkgsComputerName' `
    -Restore 'Restore-WinPkgsComputerName' -Describe 'Format-WinPkgsComputerNameChange'
