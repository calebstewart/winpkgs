<#
    winpkgs/registryKey - whether a key exists at all.

    The value resource creates keys on the way to writing a value and never
    deletes them, which is right for values but leaves no way to say "this key
    should not be here" -- the Windows 11 classic context menu is switched off
    again by removing a key, not a value.

    A key takes its values and its whole subtree with it when it goes, so the
    delete is the one direction that asks about ownership: winpkgs deletes a key
    it created -- putting the machine back as it was -- and refuses one it has no
    record of creating, where the same delete would destroy somebody else's data.
    `force` says to delete it anyway, which is how a module that knows exactly
    which key it means (windows.explorer.contextMenu) expresses itself. See the
    ownership section of Resources/Registry.ps1.

    properties: key, present, force, restartExplorer
#>

function Get-WinPkgsRegistryKeyState {
    param([hashtable]$Properties, [hashtable]$Context)
    $path = ConvertTo-WinPkgsRegistryPath -Key $Properties['key']
    return @{
        exists = [bool](Test-Path -LiteralPath $path)
        owned  = (Test-WinPkgsRegistryKeyOwned -Key $Properties['key'] -Context $Context)
    }
}

function Test-WinPkgsRegistryKeyState {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    return ([bool]$Current['exists'] -eq [bool]$Properties['present'])
}

function Test-WinPkgsRegistryKeyDeletable {
    # A key winpkgs created, or one a definition says to delete regardless.
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if ($Properties['force']) { return $true }
    if ($Current['owned']) { return $true }
    # $Current may be a plan's, read before this apply created the key.
    return (Test-WinPkgsRegistryKeyOwned -Key $Properties['key'] -Context $Context)
}

function Backup-WinPkgsRegistryKeyState {
    # A deleted key takes its values and subkeys with it, and none of that fits
    # in the journal, so export the subtree beside it, the way the file
    # resource keeps the content it overwrites. It is the record of what the
    # apply deleted; `reg import` of it puts the key back by hand.
    #
    # Nothing is exported for a key this apply will refuse to delete: there is
    # no deletion to keep the record of, and the export would copy a subtree
    # winpkgs does not manage into its own state.
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context, [string]$BackupDir)
    if (-not $Current['exists']) { return @{} }
    if (-not $Properties['present'] -and
        -not (Test-WinPkgsRegistryKeyDeletable -Properties $Properties -Current $Current -Context $Context)) {
        return @{}
    }
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
    $key = [string]$Properties['key']
    $path = ConvertTo-WinPkgsRegistryPath -Key $key
    if ($Properties['present']) {
        if (-not (Test-Path -LiteralPath $path)) {
            # -Force creates the ancestors on the way as well, and every one of
            # them is winpkgs' from here on.
            $created = @(Get-WinPkgsMissingRegistryKeys -Key $key)
            New-Item -Path $path -Force | Out-Null
            Add-WinPkgsOwnedRegistryKey -Context $Context -Keys $created
        }
        return
    }
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (-not (Test-WinPkgsRegistryKeyDeletable -Properties $Properties -Current $Current -Context $Context)) {
        throw (New-WinPkgsRegistryKeyRefusal -Key $key)
    }
    Remove-Item -LiteralPath $path -Recurse -Force
    Remove-WinPkgsOwnedRegistryKey -Context $Context -Key $key
}

function New-WinPkgsRegistryKeyRefusal {
    param([Parameter(Mandatory)][string]$Key)
    return (@(
        "$Key exists, and winpkgs has no record of creating it: deleting it would take its"
        'values and everything under it with it, and the export beside the generation is a'
        'record rather than an undo. Delete the key yourself and this is in state without'
        "winpkgs touching it; or say it twice -- windows.registryKeys.`"$Key`" ="
        '{ present = false; force = true; } -- to have winpkgs delete it regardless.'
    ) -join [Environment]::NewLine)
}

function Format-WinPkgsRegistryKeyChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $from = if ($Current['exists']) { 'present' } else { 'absent' }
    $to = if ($Properties['present']) { 'present' } else { 'absent' }
    if ($from -eq $to) { return $to }
    # Describe has no context to read the ledger with, so it judges on what Get
    # already put in $Current -- enough for a plan, which is where it is shown.
    if (-not $Properties['present'] -and -not $Properties['force'] -and -not $Current['owned']) {
        return 'exists, and winpkgs has no record of creating it: refused'
    }
    return "$from -> $to"
}

Register-WinPkgsResource -Type 'winpkgs/registryKey' `
    -Get 'Get-WinPkgsRegistryKeyState' `
    -Test 'Test-WinPkgsRegistryKeyState' `
    -Set 'Set-WinPkgsRegistryKeyState' `
    -Backup 'Backup-WinPkgsRegistryKeyState' `
    -Describe 'Format-WinPkgsRegistryKeyChange'
