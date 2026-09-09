<#
    winpkgs/wallpaper - the desktop background: an image with a fit, a solid
    colour, or both (the colour shows beside an image that does not cover the
    screen). One resource per user.

    properties: image (a path, %VAR% allowed; "" for none), fit (fill | fit |
                stretch | center | tile | span), background ("#rrggbb" or null)

    Windows keeps this under HKCU\Control Panel\Desktop (Wallpaper,
    WallpaperStyle, TileWallpaper) and HKCU\Control Panel\Colors (Background),
    but only reads those at logon. SystemParametersInfo(SPI_SETDESKWALLPAPER)
    repaints the desktop and writes the values itself; SetSysColors does the
    same for the colour. Get compares the values, so the resource is in state
    across logons whatever set it.

    WINPKGS_WALLPAPER_KEY and WINPKGS_COLORS_KEY redirect the keys (tests); the
    calls that touch the live desktop are skipped when they are set.
#>

$script:WallpaperFits = @{
    center  = @{ style = '0'; tile = '0' }
    tile    = @{ style = '0'; tile = '1' }
    stretch = @{ style = '2'; tile = '0' }
    fit     = @{ style = '6'; tile = '0' }
    fill    = @{ style = '10'; tile = '0' }
    span    = @{ style = '22'; tile = '0' }
}

function Get-WinPkgsWallpaperKeys {
    if ($env:WINPKGS_WALLPAPER_KEY -and $env:WINPKGS_COLORS_KEY) {
        return @{ desktop = $env:WINPKGS_WALLPAPER_KEY; colors = $env:WINPKGS_COLORS_KEY; live = $false }
    }
    return @{ desktop = 'HKCU\Control Panel\Desktop'; colors = 'HKCU\Control Panel\Colors'; live = $true }
}

function ConvertTo-WinPkgsColorTriplet {
    # "#rrggbb" -> "r g b", the form Control Panel\Colors uses.
    param([string]$Hex)
    $n = [Convert]::ToInt32($Hex.TrimStart('#'), 16)
    return ('{0} {1} {2}' -f (($n -shr 16) -band 0xff), (($n -shr 8) -band 0xff), ($n -band 0xff))
}

function Get-WinPkgsWallpaperValue {
    param([string]$Key, [string]$Name)
    $v = Get-WinPkgsRegistryValue -Properties @{ key = $Key; name = $Name }
    if ($v['exists']) { return [string]$v['value'] }
    return $null
}

function Resolve-WinPkgsWallpaperImage {
    param([string]$Image)
    if (-not $Image) { return '' }
    return (Resolve-WinPkgsFileTarget -Target $Image)
}

function Get-WinPkgsWallpaper {
    param([hashtable]$Properties, [hashtable]$Context)
    $k = Get-WinPkgsWallpaperKeys
    return @{
        exists     = $true
        image      = [string](Get-WinPkgsWallpaperValue -Key $k.desktop -Name 'Wallpaper')
        style      = Get-WinPkgsWallpaperValue -Key $k.desktop -Name 'WallpaperStyle'
        tile       = Get-WinPkgsWallpaperValue -Key $k.desktop -Name 'TileWallpaper'
        background = Get-WinPkgsWallpaperValue -Key $k.colors -Name 'Background'
    }
}

function Test-WinPkgsWallpaper {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $want = Resolve-WinPkgsWallpaperImage -Image $Properties['image']
    if ([string]$Current['image'] -ne $want) { return $false }
    if ($want) {
        $fit = $script:WallpaperFits[[string]$Properties['fit']]
        if (-not $fit) { throw "Unknown wallpaper fit '$($Properties['fit'])'" }
        if ([string]$Current['style'] -ne $fit.style -or [string]$Current['tile'] -ne $fit.tile) { return $false }
    }
    if ($Properties['background']) {
        if ([string]$Current['background'] -ne (ConvertTo-WinPkgsColorTriplet $Properties['background'])) { return $false }
    }
    return $true
}

function Write-WinPkgsWallpaperState {
    # Write the values, then make the desktop follow them.
    param([string]$Image, [string]$Style, [string]$Tile, [string]$Background)
    $k = Get-WinPkgsWallpaperKeys
    if ($null -ne $Background) {
        Write-WinPkgsRegistryValue -Key $k.colors -Name 'Background' -Kind String -Value $Background
        if ($k.live) {
            $parts = $Background -split ' '
            $colorref = [int]$parts[0] + ([int]$parts[1] -shl 8) + ([int]$parts[2] -shl 16)
            Initialize-WinPkgsNative
            [void][WinPkgs.Native.User32]::SetSysColors(1, [int[]]@(1), [int[]]@($colorref))   # COLOR_BACKGROUND
        }
    }
    if ($null -ne $Style) { Write-WinPkgsRegistryValue -Key $k.desktop -Name 'WallpaperStyle' -Kind String -Value $Style }
    if ($null -ne $Tile) { Write-WinPkgsRegistryValue -Key $k.desktop -Name 'TileWallpaper' -Kind String -Value $Tile }
    Write-WinPkgsRegistryValue -Key $k.desktop -Name 'Wallpaper' -Kind String -Value $Image
    if ($k.live) {
        if ($Image -and -not (Test-Path -LiteralPath $Image -PathType Leaf)) { throw "Wallpaper image not found: $Image" }
        Initialize-WinPkgsNative
        # SPI_SETDESKWALLPAPER, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
        if (-not [WinPkgs.Native.User32]::SystemParametersInfoW(0x0014, 0, $Image, 0x0003)) {
            throw "SystemParametersInfo(SPI_SETDESKWALLPAPER) failed for '$Image' (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
    }
}

function Set-WinPkgsWallpaper {
    param([hashtable]$Properties, [hashtable]$Current, [hashtable]$Context)
    $image = Resolve-WinPkgsWallpaperImage -Image $Properties['image']
    $style = $null
    $tile = $null
    if ($image) {
        $fit = $script:WallpaperFits[[string]$Properties['fit']]
        if (-not $fit) { throw "Unknown wallpaper fit '$($Properties['fit'])'" }
        $style = $fit.style
        $tile = $fit.tile
    }
    $background = $null
    if ($Properties['background']) { $background = ConvertTo-WinPkgsColorTriplet $Properties['background'] }
    Write-WinPkgsWallpaperState -Image $image -Style $style -Tile $tile -Background $background
}

function Restore-WinPkgsWallpaper {
    param([hashtable]$Properties, [hashtable]$Before, [hashtable]$Context)
    # Everything Get recorded goes back as it was; a value that did not exist stays untouched.
    Write-WinPkgsWallpaperState -Image ([string]$Before['image']) -Style $Before['style'] -Tile $Before['tile'] -Background $Before['background']
}

function Format-WinPkgsWallpaperChange {
    param([hashtable]$Properties, [hashtable]$Current)
    $parts = @()
    if ($Properties['image']) { $parts += "$($Properties['image']) ($($Properties['fit']))" } else { $parts += 'no image' }
    if ($Properties['background']) { $parts += "background $($Properties['background'])" }
    return ($parts -join ', ')
}

Register-WinPkgsResource -Type 'winpkgs/wallpaper' `
    -Get 'Get-WinPkgsWallpaper' `
    -Test 'Test-WinPkgsWallpaper' `
    -Set 'Set-WinPkgsWallpaper' `
    -Restore 'Restore-WinPkgsWallpaper' `
    -Describe 'Format-WinPkgsWallpaperChange'
