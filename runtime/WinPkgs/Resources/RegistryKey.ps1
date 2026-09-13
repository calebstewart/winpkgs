<#
    winpkgs/registryKey - whether a key exists at all.

    The value resource creates keys on the way to writing a value and never
    deletes them, which is right for values but leaves no way to say "this key
    should not be here" -- the Windows 11 classic context menu is switched off
    again by removing a key, not a value.

    properties: key, present, restartExplorer
#>

function Get-WinPkgsRegistryKeyState {
    param([hashtable]$Properties, [hashtable]$Context)
    $path = ConvertTo-WinPkgsRegistryPath -Key $Properties['key']
    return @{ exists = [bool](Test-Path -LiteralPath $path) }
}

function Test-WinPkgsRegistryKeyState {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    return ([bool]$Current['exists'] -eq [bool]$Properties['present'])
}

function Backup-WinPkgsRegistryKeyState {
    # A deleted key takes its values and subkeys with it, and none of that fits
    # in the journal, so export the subtree beside it, the way the file
    # resource keeps the content it overwrites. It is the record of what the
    # apply deleted; `reg import` of it puts the key back by hand.
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context, [string]$BackupDir)
    if (-not $Current['exists']) { return @{} }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $file = Join-Path $BackupDir 'key.reg'
    $r = Invoke-WinPkgsReg -Arguments @('export', $Properties['key'], $file, '/y')
    if ($r['failed']) { throw "reg export failed for $($Properties['key']): $($r['text'])" }
    return @{ backup = $file }
}

function Invoke-WinPkgsReg {
    # reg.exe chats on stderr even when it succeeds; Invoke-WinPkgsExternal
    # (Private/External.ps1) keeps that -- and a non-zero exit -- from becoming
    # a terminating error before the exit code can be judged.
    param([string[]]$Arguments)
    return Invoke-WinPkgsExternal -Command 'reg.exe' -Arguments $Arguments
}

function Set-WinPkgsRegistryKeyState {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $path = ConvertTo-WinPkgsRegistryPath -Key $Properties['key']
    if ($Properties['present']) {
        if (-not $Current['exists']) { New-Item -Path $path -Force | Out-Null }
        return
    }
    if ($Current['exists']) { Remove-Item -LiteralPath $path -Recurse -Force }
}

function Format-WinPkgsRegistryKeyChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $from = if ($Current['exists']) { 'present' } else { 'absent' }
    $to = if ($Properties['present']) { 'present' } else { 'absent' }
    if ($from -eq $to) { return $to }
    return "$from -> $to"
}

Register-WinPkgsResource -Type 'winpkgs/registryKey' `
    -Get 'Get-WinPkgsRegistryKeyState' `
    -Test 'Test-WinPkgsRegistryKeyState' `
    -Set 'Set-WinPkgsRegistryKeyState' `
    -Backup 'Backup-WinPkgsRegistryKeyState' `
    -Describe 'Format-WinPkgsRegistryKeyChange'
