<#
    winpkgs/font - a font package, installed from its files. Every font file in
    the package's closure directory is copied into the fonts directory of the
    scope and registered under the Fonts key, which is what makes Windows load
    it at logon; AddFontResource and a WM_FONTCHANGE broadcast make it usable
    at once.

      user     %LOCALAPPDATA%\Microsoft\Windows\Fonts  HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts  value: full path
      machine  %WINDIR%\Fonts                          HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts   value: file name

    properties: name, source (relative to the document; null once the font has
                left the configuration), scope, files (a pruned font: what it
                installed, from the ledger)

    A value is named "<file stem> (TrueType)" or "(OpenType)", the convention
    the Fonts control panel shows; the face names an application asks for come
    from the files themselves. One resource per package; a file that is missing,
    differs, or is unregistered is drift.

    The ledger (state.owned.fonts: name -> file names) is how a font is found
    again once the document no longer carries its files: to be pruned, or on
    the rollback of a prune. Whatever winpkgs put in the fonts directory it
    owns; a hand-installed file of the same name is the same font, and a
    backup makes its removal reversible.

    WINPKGS_FONT_DIR and WINPKGS_FONT_KEY redirect the location (tests).
#>

function Get-WinPkgsFontLocation {
    param([hashtable]$Properties)
    if ($env:WINPKGS_FONT_DIR -and $env:WINPKGS_FONT_KEY) {
        return @{ dir = $env:WINPKGS_FONT_DIR; key = $env:WINPKGS_FONT_KEY; fullPath = $true }
    }
    if ($Properties['scope'] -eq 'machine') {
        return @{
            dir      = Join-Path $env:WINDIR 'Fonts'
            key      = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
            fullPath = $false
        }
    }
    return @{
        dir      = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        key      = 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        fullPath = $true
    }
}

function Get-WinPkgsFontValueName {
    param([Parameter(Mandatory)][string]$FileName)
    $stem = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $kind = 'TrueType'
    if ([IO.Path]::GetExtension($FileName) -ieq '.otf') { $kind = 'OpenType' }
    return "$stem ($kind)"
}

function Get-WinPkgsFontValueData {
    # What the registry value must say: Windows expects a bare file name for a
    # font in %WINDIR%\Fonts and a full path anywhere else.
    param([hashtable]$Location, [string]$FileName)
    if ($Location.fullPath) { return (Join-Path $Location.dir $FileName) }
    return $FileName
}

function Get-WinPkgsFontSource {
    # The font's directory in the closure, or $null when the document at hand
    # does not carry it (a pruned font; a rollback).
    param([hashtable]$Properties, [hashtable]$Context)
    if (-not $Properties['source'] -or -not $Context -or -not $Context['Root']) { return $null }
    $dir = Join-Path $Context['Root'] $Properties['source']
    if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
    return $null
}

function Get-WinPkgsFontSourceFiles {
    param([string]$Source)
    return @(Get-ChildItem -LiteralPath $Source -File | ForEach-Object Name | Sort-Object)
}

function Get-WinPkgsFontFileNames {
    # Which files the font consists of: the closure knows when it is at hand;
    # otherwise the properties (a prune entry), then the ledger (a rollback).
    param([hashtable]$Properties, [hashtable]$Context)
    $source = Get-WinPkgsFontSource -Properties $Properties -Context $Context
    if ($source) { return (Get-WinPkgsFontSourceFiles -Source $source) }
    if ($Properties['files']) { return @($Properties['files']) }
    if ($Context -and $Context['State']) {
        $fonts = $Context['State']['owned']['fonts']
        if ($fonts -and $fonts.ContainsKey($Properties['name'])) { return @($fonts[$Properties['name']]) }
    }
    return @()
}

function Add-WinPkgsFontResource {
    # Load a font into the session. Best effort: the registration is what
    # persists, and the file is loaded at the next logon regardless.
    param([string]$Path)
    try {
        Initialize-WinPkgsNative
        if ([WinPkgs.Native.Gdi32]::AddFontResourceW($Path) -eq 0) { Write-Verbose "AddFontResource: nothing loaded from $Path" }
    } catch {
        Write-Verbose "AddFontResource failed for ${Path}: $($_.Exception.Message)"
    }
}

function Remove-WinPkgsFontResource {
    param([string]$Path)
    try {
        Initialize-WinPkgsNative
        [void][WinPkgs.Native.Gdi32]::RemoveFontResourceW($Path)
    } catch {
        Write-Verbose "RemoveFontResource failed for ${Path}: $($_.Exception.Message)"
    }
}

function Send-WinPkgsFontChange {
    Send-WinPkgsBroadcast -Message 0x001D -Param ([NullString]::Value)   # WM_FONTCHANGE
}

function Set-WinPkgsOwnedFont {
    param([hashtable]$Context, [Parameter(Mandatory)][string]$Name, [string[]]$Files)
    if (-not $Context -or -not $Context['State']) { return }
    $Context['State']['owned']['fonts'][$Name] = @($Files)
}

function Remove-WinPkgsOwnedFont {
    param([hashtable]$Context, [Parameter(Mandatory)][string]$Name)
    if (-not $Context -or -not $Context['State']) { return }
    $Context['State']['owned']['fonts'].Remove($Name)
}

function Remove-WinPkgsFontValue {
    param([string]$Key, [string]$Name)
    $current = Get-WinPkgsRegistryValue -Properties @{ key = $Key; name = $Name }
    if ($current['exists']) { Remove-WinPkgsRegistryValue -Key $Key -Name $Name }
}

function Get-WinPkgsFont {
    param([hashtable]$Properties, [hashtable]$Context)
    $loc = Get-WinPkgsFontLocation -Properties $Properties
    $files = @{}
    $any = $false
    foreach ($name in Get-WinPkgsFontFileNames -Properties $Properties -Context $Context) {
        $target = Join-Path $loc.dir $name
        $entry = @{ exists = $false; hash = $null; registered = $null }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $entry['exists'] = $true
            $entry['hash'] = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        }
        $value = Get-WinPkgsRegistryValue -Properties @{ key = $loc.key; name = (Get-WinPkgsFontValueName $name) }
        if ($value['exists']) { $entry['registered'] = [string]$value['value'] }
        if ($entry['exists'] -or $null -ne $entry['registered']) { $any = $true }
        $files[$name] = $entry
    }
    return @{ exists = $any; dir = $loc.dir; key = $loc.key; files = $files }
}

function Test-WinPkgsFont {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $source = Get-WinPkgsFontSource -Properties $Properties -Context $Context
    if (-not $source) { throw "Source missing from closure: $($Properties['source'])" }
    $loc = Get-WinPkgsFontLocation -Properties $Properties
    $have = $Current['files']
    if (-not $have) { return $false }
    foreach ($name in Get-WinPkgsFontSourceFiles -Source $source) {
        $entry = $have[$name]
        if (-not $entry -or -not $entry['exists']) { return $false }
        if ($entry['hash'] -ne (Get-FileHash -LiteralPath (Join-Path $source $name) -Algorithm SHA256).Hash) { return $false }
        if ($entry['registered'] -ne (Get-WinPkgsFontValueData -Location $loc -FileName $name)) { return $false }
    }
    return $true
}

function Set-WinPkgsFont {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $source = Get-WinPkgsFontSource -Properties $Properties -Context $Context
    if (-not $source) { throw "Source missing from closure: $($Properties['source'])" }
    $loc = Get-WinPkgsFontLocation -Properties $Properties
    if (-not (Test-Path -LiteralPath $loc.dir)) { New-Item -ItemType Directory -Force -Path $loc.dir | Out-Null }
    $have = @{}
    if ($Current -and $Current['files']) { $have = $Current['files'] }

    $names = Get-WinPkgsFontSourceFiles -Source $source
    foreach ($name in $names) {
        $from = Join-Path $source $name
        $target = Join-Path $loc.dir $name
        $entry = $have[$name]
        $desired = (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
        if (-not $entry -or -not $entry['exists'] -or $entry['hash'] -ne $desired) {
            # A file the session has loaded cannot be overwritten; unload it first.
            if ($entry -and $entry['exists']) { Remove-WinPkgsFontResource -Path $target }
            try {
                Copy-Item -LiteralPath $from -Destination $target -Force
            } catch {
                throw "Cannot write $target ($($_.Exception.Message)); a font in use is released by signing out"
            }
            Clear-WinPkgsReadOnly -Path $target
        }
        Write-WinPkgsRegistryValue -Key $loc.key -Name (Get-WinPkgsFontValueName $name) -Kind String -Value (Get-WinPkgsFontValueData -Location $loc -FileName $name)
        Add-WinPkgsFontResource -Path $target
    }
    Send-WinPkgsFontChange
    Set-WinPkgsOwnedFont -Context $Context -Name $Properties['name'] -Files $names
}

function Backup-WinPkgsFont {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context, [string]$BackupDir)
    if (-not $Current -or -not $Current['files']) { return @{} }
    $present = @($Current['files'].Keys | Where-Object { $Current['files'][$_]['exists'] })
    if ($present.Count -eq 0) { return @{} }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    foreach ($name in $present) {
        Copy-Item -LiteralPath (Join-Path $Current['dir'] $name) -Destination (Join-Path $BackupDir $name) -Force
    }
    return @{ backup = $BackupDir }
}

function Restore-WinPkgsFont {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $loc = Get-WinPkgsFontLocation -Properties $Properties
    $recorded = $Before['files']
    $names = @()
    if ($recorded) { $names = @($recorded.Keys | Sort-Object) }
    else { $names = @(Get-WinPkgsFontFileNames -Properties $Properties -Context $Context) }

    $kept = @()
    foreach ($name in $names) {
        $target = Join-Path $loc.dir $name
        $entry = $null
        if ($recorded) { $entry = $recorded[$name] }
        $valueName = Get-WinPkgsFontValueName $name

        if ($entry -and $entry['exists']) {
            if (-not $Before['backup']) { throw "No backup recorded for $target; cannot restore" }
            Remove-WinPkgsFontResource -Path $target
            try {
                Copy-Item -LiteralPath (Join-Path $Before['backup'] $name) -Destination $target -Force
            } catch {
                throw "Cannot write $target ($($_.Exception.Message)); a font in use is released by signing out"
            }
            Clear-WinPkgsReadOnly -Path $target
            Add-WinPkgsFontResource -Path $target
            $kept += $name
        } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-WinPkgsFontResource -Path $target
            try {
                Remove-Item -LiteralPath $target -Force
            } catch {
                throw "Cannot delete $target ($($_.Exception.Message)); a font in use is released by signing out"
            }
        }

        if ($entry -and $null -ne $entry['registered']) {
            Write-WinPkgsRegistryValue -Key $loc.key -Name $valueName -Kind String -Value $entry['registered']
        } else {
            Remove-WinPkgsFontValue -Key $loc.key -Name $valueName
        }
    }
    Send-WinPkgsFontChange

    # The ledger: a prune rolled back owns its files again; a create undone
    # owns nothing; an update undone keeps what an earlier generation recorded.
    if ($Before['owned'] -and $kept.Count -gt 0) {
        Set-WinPkgsOwnedFont -Context $Context -Name $Properties['name'] -Files $kept
    } elseif ($kept.Count -eq 0) {
        Remove-WinPkgsOwnedFont -Context $Context -Name $Properties['name']
    }
}

function Format-WinPkgsFontChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $files = $Current['files']
    $n = 0
    $present = 0
    if ($files) {
        $n = @($files.Keys).Count
        $present = @($files.Keys | Where-Object { $files[$_]['exists'] }).Count
    }
    if (-not $Current['exists']) { return "$n font file(s)" }
    if ($present -eq $n) { return "$n font file(s) present" }
    return "$present of $n font file(s) present"
}

Register-WinPkgsResource -Type 'winpkgs/font' `
    -Get 'Get-WinPkgsFont' `
    -Test 'Test-WinPkgsFont' `
    -Set 'Set-WinPkgsFont' `
    -Restore 'Restore-WinPkgsFont' `
    -Backup 'Backup-WinPkgsFont' `
    -Describe 'Format-WinPkgsFontChange'
