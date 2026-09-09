<#
    winpkgs/pointer - the mouse pointer: which cursor set, how big. User scope.

    properties: scheme (a name under the Cursors\Schemes key, or null to leave
                the files), name (what the Cursors key's default value shows for
                it), type (the accessibility code Settings keeps for the style:
                3 white, 4 black, 5 inverted; or null), size (1-15 or null)

    Windows keeps the seventeen cursor files under HKCU\Control Panel\Cursors,
    one value per role, and the named sets under a Schemes key in HKLM (and
    HKCU for ones a user added) as one comma-separated string in that same
    role order -- so a set is applied by name, from what the machine itself
    defines, not from a list kept here. The size lives beside them, as the
    slider value and the base size in pixels it implies. SystemParametersInfo
    (SPI_SETCURSORS) reloads the lot. Settings itself does something else on
    Windows 11 -- renders the style from SVGs into per-user files -- which is
    why a custom colour is not a property here.

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

function Get-WinPkgsCursorScheme {
    # Role -> file for a named scheme, from wherever the machine defines it.
    param([string]$Name)
    $k = Get-WinPkgsPointerKeys
    foreach ($key in $k.schemes) {
        $raw = Get-WinPkgsPointerValue -Key $key -Name $Name
        if ($null -eq $raw) { continue }
        $parts = [string]$raw -split ','
        $files = @{}
        for ($i = 0; $i -lt $script:CursorRoles.Count; $i++) {
            $files[$script:CursorRoles[$i]] = if ($i -lt $parts.Count) { $parts[$i].Trim() } else { '' }
        }
        return $files
    }
    throw "No cursor scheme named '$Name' is defined on this machine"
}

function Get-WinPkgsCursorBaseSize {
    # The slider's 1-15 against the base size in pixels Windows derives from it.
    param([int]$Size)
    return 16 * ($Size + 1)
}

function Get-WinPkgsPointer {
    param([hashtable]$Properties, [hashtable]$Context)
    $k = Get-WinPkgsPointerKeys
    $files = @{}
    foreach ($role in $script:CursorRoles) { $files[$role] = Get-WinPkgsPointerValue -Key $k.cursors -Name $role }
    return @{
        exists   = $true
        files    = $files
        name     = Get-WinPkgsPointerValue -Key $k.cursors -Name ''
        baseSize = Get-WinPkgsPointerValue -Key $k.cursors -Name 'CursorBaseSize'
        type     = Get-WinPkgsPointerValue -Key $k.accessibility -Name 'CursorType'
        size     = Get-WinPkgsPointerValue -Key $k.accessibility -Name 'CursorSize'
    }
}

function Test-WinPkgsPointer {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    if ($Properties['scheme']) {
        $want = Get-WinPkgsCursorScheme -Name $Properties['scheme']
        foreach ($role in $script:CursorRoles) {
            if ([string]$Current['files'][$role] -ne [string]$want[$role]) { return $false }
        }
        if ([string]$Current['name'] -ne [string]$Properties['name']) { return $false }
    }
    if ($null -ne $Properties['size']) {
        if ([string]$Current['size'] -ne [string]$Properties['size']) { return $false }
        if ([string]$Current['baseSize'] -ne [string](Get-WinPkgsCursorBaseSize -Size $Properties['size'])) { return $false }
    }
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
    if ($Properties['scheme']) {
        $files = Get-WinPkgsCursorScheme -Name $Properties['scheme']
        foreach ($role in $script:CursorRoles) {
            Write-WinPkgsRegistryValue -Key $k.cursors -Name $role -Kind ExpandString -Value ([string]$files[$role])
        }
        Write-WinPkgsRegistryValue -Key $k.cursors -Name '' -Kind String -Value ([string]$Properties['name'])
        Write-WinPkgsRegistryValue -Key $k.cursors -Name 'Scheme Source' -Kind DWord -Value 2
    }
    if ($null -ne $Properties['size']) {
        Write-WinPkgsRegistryValue -Key $k.accessibility -Name 'CursorSize' -Kind DWord -Value ([int]$Properties['size'])
        Write-WinPkgsRegistryValue -Key $k.cursors -Name 'CursorBaseSize' -Kind DWord -Value (Get-WinPkgsCursorBaseSize -Size $Properties['size'])
    }
    if ($null -ne $Properties['type']) {
        Write-WinPkgsRegistryValue -Key $k.accessibility -Name 'CursorType' -Kind DWord -Value ([int]$Properties['type'])
    }
    Send-WinPkgsCursorChange
}

function Restore-WinPkgsPointer {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    $k = Get-WinPkgsPointerKeys
    if ($Properties['scheme']) {
        foreach ($role in $script:CursorRoles) {
            Write-WinPkgsPointerValue -Key $k.cursors -Name $role -Kind ExpandString -Value $Before['files'][$role]
        }
        Write-WinPkgsPointerValue -Key $k.cursors -Name '' -Kind String -Value $Before['name']
    }
    if ($null -ne $Properties['size']) {
        Write-WinPkgsPointerValue -Key $k.accessibility -Name 'CursorSize' -Kind DWord -Value $Before['size']
        Write-WinPkgsPointerValue -Key $k.cursors -Name 'CursorBaseSize' -Kind DWord -Value $Before['baseSize']
    }
    if ($null -ne $Properties['type']) { Write-WinPkgsPointerValue -Key $k.accessibility -Name 'CursorType' -Kind DWord -Value $Before['type'] }
    Send-WinPkgsCursorChange
}

function Format-WinPkgsPointerChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $parts = @()
    if ($Properties['scheme']) { $parts += "$($Current['name']) -> $($Properties['name'])" }
    if ($null -ne $Properties['size']) { $parts += "size $(if ($null -ne $Current['size']) { $Current['size'] } else { 1 }) -> $($Properties['size'])" }
    return ($parts -join ', ')
}

Register-WinPkgsResource -Type 'winpkgs/pointer' `
    -Get 'Get-WinPkgsPointer' -Test 'Test-WinPkgsPointer' -Set 'Set-WinPkgsPointer' `
    -Restore 'Restore-WinPkgsPointer' -Describe 'Format-WinPkgsPointerChange'
