# The wallpaper resource against redirected keys, so the real desktop is never
# touched: values, fits, the solid colour, and restore.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $env:WINPKGS_WALLPAPER_KEY = "$TestKey\Desktop"
    $env:WINPKGS_COLORS_KEY = "$TestKey\Colors"
    $env:WINPKGS_TEST_HOME = Join-Path $TestDrive 'home'
    New-Item -ItemType Directory -Force -Path $env:WINPKGS_TEST_HOME | Out-Null
    Set-Content -LiteralPath (Join-Path $env:WINPKGS_TEST_HOME 'wall.jpg') -Value 'not really a jpeg' -NoNewline

    function Op([string]$Operation, [hashtable]$P, [hashtable]$Current, [hashtable]$Before) {
        $splat = @{ Type = 'winpkgs/wallpaper'; Operation = $Operation; Properties = $P; Context = @{} }
        if ($Current) { $splat['Current'] = $Current }
        if ($Before) { $splat['Before'] = $Before }
        Invoke-WinPkgsResource @splat
    }
    function Value([string]$Sub, [string]$Name) {
        $path = 'Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5) + "\$Sub"
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        (Get-Item -LiteralPath $path).GetValue($Name, $null)
    }
    $Image = @{ image = '%WINPKGS_TEST_HOME%\wall.jpg'; fit = 'fill'; background = $null }
}

AfterAll {
    Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)) -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($v in 'WINPKGS_WALLPAPER_KEY', 'WINPKGS_COLORS_KEY', 'WINPKGS_TEST_HOME') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
}

Describe 'winpkgs/wallpaper' {
    It 'starts out of state on a fresh key, sets image, style and tile, then is in state' {
        $c = Op Get $Image
        $c.exists | Should -BeTrue
        Op Test $Image $c | Should -BeFalse
        Op Describe $Image $c | Should -Be '%WINPKGS_TEST_HOME%\wall.jpg (fill)'
        Op Set $Image $c
        Value Desktop Wallpaper | Should -Be (Join-Path $env:WINPKGS_TEST_HOME 'wall.jpg')
        Value Desktop WallpaperStyle | Should -Be '10'
        Value Desktop TileWallpaper | Should -Be '0'
        Op Test $Image (Op Get $Image) | Should -BeTrue
    }

    It 'a different fit is drift; tile sets the tile flag' {
        $tiled = @{ image = '%WINPKGS_TEST_HOME%\wall.jpg'; fit = 'tile'; background = $null }
        $c = Op Get $tiled
        Op Test $tiled $c | Should -BeFalse
        Op Set $tiled $c
        Value Desktop WallpaperStyle | Should -Be '0'
        Value Desktop TileWallpaper | Should -Be '1'
        Op Test $tiled (Op Get $tiled) | Should -BeTrue
        Op Test $Image (Op Get $Image) | Should -BeFalse
    }

    It 'a solid colour clears the image and writes the triplet' {
        $solid = @{ image = ''; fit = 'fill'; background = '#1e1e2e' }
        $c = Op Get $solid
        Op Test $solid $c | Should -BeFalse
        Op Describe $solid $c | Should -Be 'no image, background #1e1e2e'
        Op Set $solid $c
        Value Desktop Wallpaper | Should -Be ''
        Value Colors Background | Should -Be '30 30 46'
        Op Test $solid (Op Get $solid) | Should -BeTrue
    }

    It 'an image with a background checks both' {
        $both = @{ image = '%WINPKGS_TEST_HOME%\wall.jpg'; fit = 'fit'; background = '#ffffff' }
        Op Test $both (Op Get $both) | Should -BeFalse
        Op Set $both (Op Get $both)
        Value Colors Background | Should -Be '255 255 255'
        Value Desktop WallpaperStyle | Should -Be '6'
        Op Test $both (Op Get $both) | Should -BeTrue
        # a colour change alone is drift
        $other = @{ image = '%WINPKGS_TEST_HOME%\wall.jpg'; fit = 'fit'; background = '#000000' }
        Op Test $other (Op Get $other) | Should -BeFalse
    }

    It 'restores what Get recorded' {
        $before = Op Get $Image   # the state the previous test left: fit, white
        Op Set $Image $before
        Value Desktop WallpaperStyle | Should -Be '10'
        Op Restore $Image $null $before
        Value Desktop WallpaperStyle | Should -Be '6'
        Value Colors Background | Should -Be '255 255 255'
        Value Desktop Wallpaper | Should -Be (Join-Path $env:WINPKGS_TEST_HOME 'wall.jpg')
    }

    It 'rejects an unknown fit' {
        $bad = @{ image = '%WINPKGS_TEST_HOME%\wall.jpg'; fit = 'mosaic'; background = $null }
        { Op Test $bad (Op Get $bad) } | Should -Throw '*Unknown wallpaper fit*'
    }
}
