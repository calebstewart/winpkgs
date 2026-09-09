<#
    winpkgs/pointer - the mouse pointer: which cursor set. User scope.

    properties: scheme (a name under the Cursors\Schemes key), name (what the
                Cursors key's default value shows for it), type (the
                accessibility code Settings keeps for the style: 3 white,
                4 black, 5 inverted; or null)

    Windows keeps the seventeen cursor files under HKCU\Control Panel\Cursors,
    one value per role, and the named sets under a Schemes key in HKLM (and
    HKCU for ones a user added) as one comma-separated string in that same
    role order -- so a set is applied by name, from what the machine itself
    defines, not from a list kept here. SystemParametersInfo (SPI_SETCURSORS)
    reloads the lot. Settings does something else on Windows 11 -- renders a
    style from SVGs into per-user files at a chosen size and colour -- which
    is why neither the size slider nor a colour is a property here; the
    stock sets are fixed-size files, and their large variants are sets of
    their own.

    WINPKGS_CURSORS_KEY, WINPKGS_ACCESSIBILITY_KEY and WINPKGS_CURSOR_SCHEMES_KEY
    redirect the keys (tests); the live call is skipped when they are set.
#>

$script:CursorRoles = @(
    'Arrow', 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam', 'NWPen', 'No',
    'SizeNS', 'SizeWE', 'SizeNWSE', 'SizeNESW', 'SizeAll', 'UpArrow', 'Hand', 'Pin', 'Person'
)

function Get-WinPkgsPointerKeys {
    if ($env:WINPKGS_CURSORS_KEY -and $env:WINPKGS_ACCESSIBILITY_KEY -and $env:WINPKGS_CURSOR_SCHEMES_KEY) {
        return @{
            cursors       = $env:WINPKGS_CURSORS_KEY
            accessibility = $env:WINPKGS_ACCESSIBILITY_KEY
            schemes       = @($env:WINPKGS_CURSOR_SCHEMES_KEY)
            live          = $false
        }
    }
    return @{
        cursors       = 'HKCU\Control Panel\Cursors'
        accessibility = 'HKCU\Software\Microsoft\Accessibility'
        schemes       = @(
            'HKCU\Control Panel\Cursors\Schemes'
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\Cursors\Schemes'
        )
        live          = $true
    }
}

function Get-WinPkgsPointerValue {
    param([string]$Key, [string]$Name)
    $v = Get-WinPkgsRegistryValue -Properties @{ key = $Key; name = $Name }
    if ($v['exists']) { return $v['value'] }
    return $null
}

function ConvertTo-WinPkgsSchemeKey {
    # Names compare loosely: Windows itself registers one of its sets with a
    # stray parenthesis ("Windows Aero XL)"), and case is not meaning.
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function Get-WinPkgsCursorScheme {
    # Role -> file for a named scheme, from wherever the machine defines it.
    param([string]$Name)
    $k = Get-WinPkgsPointerKeys
    $wanted = ConvertTo-WinPkgsSchemeKey $Name
    foreach ($key in $k.schemes) {
        $path = ConvertTo-WinPkgsRegistryPath -Key $key
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path
        foreach ($candidate in $item.GetValueNames()) {
            if ((ConvertTo-WinPkgsSchemeKey $candidate) -ne $wanted) { continue }
            $parts = [string]$item.GetValue($candidate) -split ','
            $files = @{}
            for ($i = 0; $i -lt $script:CursorRoles.Count; $i++) {
                $files[$script:CursorRoles[$i]] = if ($i -lt $parts.Count) { $parts[$i].Trim() } else { '' }
            }
            return $files
        }
    }
    throw "No cursor scheme named '$Name' is defined on this machine"
}

function Get-WinPkgsPointer {
    param([hashtable]$Properties, [hashtable]$Context)
    $k = Get-WinPkgsPointerKeys
    $files = @{}
    foreach ($role in $script:CursorRoles) { $files[$role] = Get-WinPkgsPointerValue -Key $k.cursors -Name $role }
    return @{
        exists = $true
        files  = $files
        name   = Get-WinPkgsPointerValue -Key $k.cursors -Name ''
        type   = Get-WinPkgsPointerValue -Key $k.accessibility -Name 'CursorType'
    }
}

function Test-WinPkgsPointer {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $want = Get-WinPkgsCursorScheme -Name $Properties['scheme']
    foreach ($role in $script:CursorRoles) {
        if ([string]$Current['files'][$role] -ne [string]$want[$role]) { return $false }
    }
    if ([string]$Current['name'] -ne [string]$Properties['name']) { return $false }
    if ($null -ne $Properties['type'] -and [string]$Current['type'] -ne [string]$Properties['type']) { return $false }
    return $true
}

function Write-WinPkgsPointerValue {
    param([string]$Key, [string]$Name, [string]$Kind, $Value)
    if ($null -eq $Value) {
        $current = Get-WinPkgsRegistryValue -Properties @{ key = $Key; name = $Name }
        if ($current['exists']) { Remove-WinPkgsRegistryValue -Key $Key -Name $Name }
        return
    }
    Write-WinPkgsRegistryValue -Key $Key -Name $Name -Kind $Kind -Value $Value
}

function Send-WinPkgsCursorChange {
    $k = Get-WinPkgsPointerKeys
    if (-not $k.live) { return }
    Initialize-WinPkgsNative
    # SPI_SETCURSORS reloads the cursors from the registry. SPIF_SENDCHANGE
    # only: with SPIF_UPDATEINIFILE, which has nothing to write here, the
    # call fails and reloads nothing.
    if (-not [WinPkgs.Native.User32]::SystemParametersInfoW(0x0057, 0, [NullString]::Value, 0x0002)) {
        throw "SystemParametersInfo(SPI_SETCURSORS) failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())); the values are written and load at the next sign-in"
    }
}

function Set-WinPkgsPointer {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $k = Get-WinPkgsPointerKeys
    $files = Get-WinPkgsCursorScheme -Name $Properties['scheme']
    foreach ($role in $script:CursorRoles) {
        Write-WinPkgsRegistryValue -Key $k.cursors -Name $role -Kind ExpandString -Value ([string]$files[$role])
    }
    Write-WinPkgsRegistryValue -Key $k.cursors -Name '' -Kind String -Value ([string]$Properties['name'])
    Write-WinPkgsRegistryValue -Key $k.cursors -Name 'Scheme Source' -Kind DWord -Value 2
    if ($null -ne $Properties['type']) {
        Write-WinPkgsRegistryValue -Key $k.accessibility -Name 'CursorType' -Kind DWord -Value ([int]$Properties['type'])
    }
    Send-WinPkgsCursorChange
}

function Restore-WinPkgsPointer {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $k = Get-WinPkgsPointerKeys
    foreach ($role in $script:CursorRoles) {
        Write-WinPkgsPointerValue -Key $k.cursors -Name $role -Kind ExpandString -Value $Before['files'][$role]
    }
    Write-WinPkgsPointerValue -Key $k.cursors -Name '' -Kind String -Value $Before['name']
    if ($null -ne $Properties['type']) { Write-WinPkgsPointerValue -Key $k.accessibility -Name 'CursorType' -Kind DWord -Value $Before['type'] }
    Send-WinPkgsCursorChange
}

function Format-WinPkgsPointerChange {
    param([hashtable]$Properties, [hashtable]$Current)
    return "$($Current['name']) -> $($Properties['name'])"
}

Register-WinPkgsResource -Type 'winpkgs/pointer' `
    -Get 'Get-WinPkgsPointer' -Test 'Test-WinPkgsPointer' -Set 'Set-WinPkgsPointer' `
    -Restore 'Restore-WinPkgsPointer' -Describe 'Format-WinPkgsPointerChange'
