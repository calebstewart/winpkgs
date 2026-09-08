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
    # in the journal, so stash the subtree the way the file resource stashes
    # content. `reg import` merges rather than replaces: a value added after the
    # backup survives the restore. That is the same best-effort bargain the rest
    # of rollback makes.
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context, [string]$BackupDir)
    if (-not $Current['exists']) { return @{} }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $file = Join-Path $BackupDir 'key.reg'
    $out = & reg.exe export $Properties['key'] $file /y 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg export failed for $($Properties['key']): $out" }
    return @{ backup = $file }
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

function Restore-WinPkgsRegistryKeyState {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $path = ConvertTo-WinPkgsRegistryPath -Key $Properties['key']
    if ($Before['exists']) {
        if (-not $Before['backup']) { throw "No backup recorded for $($Properties['key']); cannot restore" }
        $out = & reg.exe import $Before['backup'] 2>&1
        if ($LASTEXITCODE -ne 0) { throw "reg import failed for $($Properties['key']): $out" }
        return
    }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
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
    -Restore 'Restore-WinPkgsRegistryKeyState' `
    -Backup 'Backup-WinPkgsRegistryKeyState' `
    -Describe 'Format-WinPkgsRegistryKeyChange'
